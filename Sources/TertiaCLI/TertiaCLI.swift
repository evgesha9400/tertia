#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import TertiaCore

public enum CLIError: Error, LocalizedError, Equatable, Sendable {
    case usage(String)
    /// `--help` or `-h` appeared in option position; the caller prints usage and exits 0.
    case helpRequested
    public var errorDescription: String? {
        switch self {
        case .usage(let message): message
        case .helpRequested: "Help requested."
        }
    }
}

func encodePrettyJSON<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? enc.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
}

func writeStderr(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }

/// Sentence appended to a message when the widget copy of a file could not be written.
func mirrorWarning(_ error: Error?) -> String {
    error.map { " Updating the widget copy failed: \($0.localizedDescription)." } ?? ""
}

/// Right-aligns a full 64-bit integer (no 32-bit `%d` truncation).
func padLeft(_ value: Int, width: Int) -> String {
    let text = String(value)
    return text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

public enum TertiaCLI {
    public static let version = "0.1.0"
    public static let subcommands: Set<String> = [
        "timetable", "clubs", "set-club", "login", "logout",
        "bookings", "book", "cancel", "mcp", "help", "--help", "-h", "version", "--version", "-v",
    ]

    public static func shouldHandle(firstArg: String?) -> Bool {
        firstArg.map(subcommands.contains) ?? false
    }

    /// Throws `CLIError.helpRequested` for `--help`/`-h` in option position (a flag value such as `--search -h` is data).
    public static func parseOptions(_ args: [String], valueFlags: Set<String> = [], boolFlags: Set<String> = []) throws -> (values: [String: String], flags: Set<String>, positionals: [String]) {
        var values: [String: String] = [:]; var flags: Set<String> = []; var positionals: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--help" || arg == "-h" { throw CLIError.helpRequested }
            if arg.hasPrefix("-") {
                if let eq = arg.firstIndex(of: "=") {
                    let key = String(arg[..<eq])
                    guard valueFlags.contains(key) else { throw CLIError.usage("Unknown option '\(key)'.") }
                    values[key] = String(arg[arg.index(after: eq)...])
                } else if valueFlags.contains(arg) {
                    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw CLIError.usage("Missing value for \(arg).") }
                    values[arg] = args[i + 1]; i += 1
                } else if boolFlags.contains(arg) {
                    flags.insert(arg)
                } else {
                    throw CLIError.usage("Unknown option '\(arg)'.")
                }
            } else {
                positionals.append(arg)
            }
            i += 1
        }
        return (values, flags, positionals)
    }

    /// Clubs offered to the current user (all 17 when signed out, else the account's timetable clubs), with any Keychain
    /// UI-restore warning from the read.
    public static func availableClubsWithWarning(store: SharedStateStore, keychain: KeychainStore) throws -> (clubs: [Club], warning: KeychainError?) {
        let (session, warning) = try keychain.readSessionWithWarning()
        return (session.map { $0.entitledClubs(from: store.publicClubCatalog()) } ?? store.signedOutClubCatalog(), warning)
    }

    /// Checks entitlement and saves the club atomically (`selectEntitledClub`), then warms its public timetable (best
    /// effort). `nil` means the club is not available to the current account; `warning` names a Keychain UI-restore
    /// warning and a failed widget-mirror write (the club itself was saved); the caller reports it once.
    public static func applyWidgetClub(clubId: Int, store: SharedStateStore, keychain: KeychainStore = KeychainStore(), client: PublicTimetableClient, onStateChanged: @Sendable () -> Void = {}) async throws -> (club: Club, warning: String?)? {
        guard let selected = try store.selectEntitledClub(clubId: clubId, keychain: keychain) else { return nil }
        _ = try? await client.fetchSchedule(clubId: selected.club.id, date: LondonCalendar.londonTodayIso(), forceRefresh: false)
        onStateChanged()
        let warning = (selected.warning.map { " \($0.localizedDescription)" } ?? "") + mirrorWarning(selected.mirrorError)
        return (selected.club, warning.isEmpty ? nil : warning)
    }

    /// Runs `op` with the Keychain session; a 401 expires the session only if the Keychain still holds that same token,
    /// and the error names what happened to it. A Keychain UI-restore warning from the read goes to stderr.
    public static func performAuthenticated<T>(store: SharedStateStore, keychain: KeychainStore, onStateChanged: @Sendable () -> Void = {}, _ op: (MemberSession) async throws -> T) async throws -> T {
        let read = try keychain.readSessionWithWarning()
        if let warning = read.warning { writeStderr("warning: \(warning.localizedDescription)") }
        guard let session = read.session else {
            throw BookingClientError.unauthorized("Not signed in. Run `tertia login --email <email>` first.")
        }
        do { return try await op(session) }
        catch where BookingClientError.isUnauthorized(error) {
            let expiry = store.expireSession(for: session, keychain: keychain)
            if expiry.didMutateDisk { onStateChanged() }
            throw BookingClientError.unauthorized("\(error.localizedDescription) \(expiry.summary)")
        }
    }

    /// Shared by `tertia bookings` and MCP `my_bookings`: live sync on `refresh`, otherwise this account's cache, or an
    /// error. Both paths hide classes already started at `nowProvider()`, sampled after any sync completes; the full
    /// list stays on disk for authorization. `warning` names a failed widget-mirror write.
    public static func memberBookings(refresh: Bool, store: SharedStateStore, keychain: KeychainStore, bookingClient: MobileBookingClient, onStateChanged: @Sendable () -> Void = {},
                                      nowProvider: () -> Date = { Date() }) async throws -> (session: MemberSession, snapshot: BookingsSnapshot, warning: String?) {
        try await performAuthenticated(store: store, keychain: keychain, onStateChanged: onStateChanged) { session in
            let snap: BookingsSnapshot, mirrorError: Error?
            if refresh {
                (snap, mirrorError) = try await bookingClient.syncBookings(for: session, store: store, keychain: keychain)
                onStateChanged()
            } else {
                guard let cached = store.loadBookings(for: session) else {
                    throw CLIError.usage("No cached bookings yet. Run `tertia bookings --refresh` (or my_bookings with refresh=true).")
                }
                (snap, mirrorError) = (cached, nil)
            }
            let now = nowProvider()
            let upcoming = snap.bookings.filter { !isKnownPastStart($0, now: now) }
            return (session, BookingsSnapshot(ownerKey: snap.ownerKey, bookings: upcoming, syncedAt: snap.syncedAt, revision: snap.revision), mirrorError.map { mirrorWarning($0) })
        }
    }

    private static func isKnownPastStart(_ booking: MemberBooking, now: Date) -> Bool {
        if case .exact(let start) = LondonCalendar.parseBookingStart(booking.startDate) { return start <= now }
        return false
    }

    /// Shared by `tertia timetable` and MCP `get_timetable` so identical inputs return identical class IDs. Without a
    /// date, the London day before the fetch is fetched (it covers the next 3 days too) and the day after the fetch is
    /// listed (tomorrow when midnight passed meanwhile, fetched through the cache-aware client when the first result
    /// lacks it) with zero grace at the clock sampled after the last fetch, so a class that started during either fetch is
    /// never listed. An explicit date lists every stored row, dropping started classes at start time when that date is
    /// today.
    public static func queryTimetable(clubId: Int?, date: String?, period: String?, search: String?, refresh: Bool, store: SharedStateStore, client: PublicTimetableClient,
                                      nowProvider: () -> Date = { Date() }) async throws -> (snapshot: TimetableSnapshot, date: String, classes: [ClassSession]) {
        let club = clubId ?? store.loadPreferences().clubId
        guard club > 0 else { throw CLIError.usage("Invalid club ID '\(club)'.") }
        let startNow = nowProvider()
        let fetchDay = date ?? LondonCalendar.londonTodayIso(now: startNow)
        guard LondonCalendar.parseIsoDate(fetchDay) != nil else { throw CLIError.usage("Invalid date '\(fetchDay)'. Expected YYYY-MM-DD.") }
        guard let schedulePeriod = SchedulePeriod(rawValue: period ?? "all") else {
            throw CLIError.usage("Invalid period '\(period ?? "")'. Expected all, morning, afternoon, or evening.")
        }
        var snap = try await client.fetchSchedule(clubId: club, date: fetchDay, forceRefresh: refresh)
        var now = max(startNow, nowProvider()), day = date ?? LondonCalendar.londonTodayIso(now: now)
        // A day missed by the first fetch (midnight passed) is fetched, then the clock and day are sampled again; at most
        // two retries, after which a still-missing day lists nothing.
        for _ in 0..<2 where day != fetchDay && !snap.hasCachedDay(day) {
            snap = try await client.fetchSchedule(clubId: club, date: day, forceRefresh: false)
            now = max(now, nowProvider()); day = date ?? LondonCalendar.londonTodayIso(now: now)
        }
        return (snap, day, LondonCalendar.filterSessions(snap.classes(for: day), period: schedulePeriod, search: search ?? "", selectedDate: day,
                                                          now: now, includePastGraceMinutes: 0))
    }

    /// Shared by `tertia book|cancel` and MCP `book_class|cancel_booking`. Any public timetable fetch happens first;
    /// then, after `.mutation.lock` is held, `BookingAuthorization` runs under the account lock on the live session, its
    /// valid bookings, and `SharedStateStore.lookupEntitledClass` over its entitled clubs (called only when needed;
    /// `nowProvider` is read there), the mutation
    /// runs, and partial outcomes are reported. When a failed mutation changed the cached bookings on disk (a dispatch
    /// invalidated them), observers are notified, so no surface keeps stale booking buttons or badges.
    public static func performMutation(classId: Int, isCancel: Bool, late: Bool, store: SharedStateStore, keychain: KeychainStore, client: PublicTimetableClient, bookingClient: MobileBookingClient, onStateChanged: @Sendable () -> Void = {}, nowProvider: @escaping @Sendable () -> Date = { Date() }) async throws -> String {
        try await performAuthenticated(store: store, keychain: keychain, onStateChanged: onStateChanged) { session in
            let entitled = Set(session.entitledClubs(from: store.publicClubCatalog()).map(\.id))
            if !isCancel, store.lookupEntitledClass(classId, clubIds: entitled) == .missing {
                _ = try? await client.fetchSchedule(clubId: store.loadPreferences().clubId, date: LondonCalendar.londonTodayIso(now: nowProvider()), forceRefresh: false)
            }
            let before = store.loadBookings(for: session)
            let outcome: MobileBookingClient.MutationOutcome
            do {
                outcome = try await bookingClient.mutateAndSync(classId: classId, isCancel: isCancel, session: session, store: store, keychain: keychain) { live, bookings, store in
                    try BookingAuthorization.authorize(classId: classId, isCancel: isCancel, bookings: bookings, confirmedLate: late, now: nowProvider(),
                                                       clubNames: store.clubNamesById()) {
                        store.lookupEntitledClass(classId, clubIds: Set(live.entitledClubs(from: store.publicClubCatalog()).map(\.id)))
                    }
                }
            } catch {
                if store.loadBookings(for: session) != before { onStateChanged() }
                throw error
            }
            onStateChanged()
            return mutationMessage(outcome, verb: isCancel ? "Cancelled" : "Booked", classId: classId)
        }
    }

    static func mutationMessage(_ outcome: MobileBookingClient.MutationOutcome, verb: String, classId: Int) -> String {
        switch outcome {
        case .synced(let snap, let mirrorError):
            return "\(verb) class \(classId). Active bookings: \(snap.bookedIds.count)." + mirrorWarning(mirrorError)
        case .acceptedRefreshFailed(let error, let followUp):
            let next = switch followUp {
            case .sessionExpired(let expiry): "The session token was rejected. \(expiry.summary)"
            case .cacheCleanup(let cleanup): cleanup.summary
            }
            return "\(verb) class \(classId), but refreshing bookings failed: \(error.localizedDescription). \(next)"
        }
    }

    public static func run(args: [String], store: SharedStateStore = SharedStateStore(), keychain: KeychainStore = KeychainStore(), client: PublicTimetableClient? = nil, bookingClient: MobileBookingClient = MobileBookingClient(), onStateChanged: @Sendable () -> Void = {}) async -> Int32 {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        let timetableClient = client ?? PublicTimetableClient(store: store)

        do {
            switch cmd {
            case "help", "--help", "-h": print(usageText)
            case "version", "--version", "-v":
                guard rest.isEmpty else { throw CLIError.usage("usage: tertia version") }
                print("tertia \(version)")
            case "timetable": try await runTimetable(args: rest, store: store, client: timetableClient)
            case "clubs": try runClubs(args: rest, store: store, keychain: keychain)
            case "set-club": try await runSetClub(args: rest, store: store, keychain: keychain, client: timetableClient, onStateChanged: onStateChanged)
            case "login": try await runLogin(args: rest, store: store, keychain: keychain, client: timetableClient, bookingClient: bookingClient, onStateChanged: onStateChanged)
            case "logout":
                try requireNoPositionals(try parseOptions(rest), usage: "usage: tertia logout")
                let (_, cacheError, warning) = try store.clearSession(keychain: keychain)
                onStateChanged()
                if let warning { writeStderr("warning: \(warning.localizedDescription)") }
                if let cacheError { throw CLIError.usage("Signed out (Keychain token removed), but clearing cached bookings failed: \(cacheError.localizedDescription)") }
                print("Signed out. Keychain token and cached bookings removed.")
            case "bookings": try await runBookings(args: rest, store: store, keychain: keychain, bookingClient: bookingClient, onStateChanged: onStateChanged)
            case "book", "cancel":
                let isCancel = cmd == "cancel"
                let parsed = try parseOptions(rest, boolFlags: isCancel ? ["--late"] : [])
                let classId = try singlePositiveInt(parsed, usage: "usage: tertia \(cmd) <class_id>\(isCancel ? " [--late]" : "")")
                print(try await performMutation(classId: classId, isCancel: isCancel, late: parsed.flags.contains("--late"), store: store, keychain: keychain, client: timetableClient, bookingClient: bookingClient, onStateChanged: onStateChanged))
            case "mcp":
                try requireNoPositionals(try parseOptions(rest), usage: "usage: tertia mcp")
                await MCPServer.run(store: store, keychain: keychain, client: timetableClient, bookingClient: bookingClient, onStateChanged: onStateChanged)
            default:
                writeStderr("error: unknown command '\(cmd)'\n\(usageText)")
                return 1
            }
            return 0
        } catch CLIError.helpRequested {
            print(usageText)
            return 0
        } catch {
            writeStderr("error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func requireNoPositionals(_ parsed: (values: [String: String], flags: Set<String>, positionals: [String]), usage: String) throws {
        guard parsed.positionals.isEmpty else { throw CLIError.usage(usage) }
    }

    private static func singlePositiveInt(_ parsed: (values: [String: String], flags: Set<String>, positionals: [String]), usage: String) throws -> Int {
        guard parsed.positionals.count == 1, let id = Int(parsed.positionals[0]), id > 0 else { throw CLIError.usage(usage) }
        return id
    }

    private static func runTimetable(args: [String], store: SharedStateStore, client: PublicTimetableClient) async throws {
        let parsed = try parseOptions(args, valueFlags: ["--club", "--date", "--period", "--search"], boolFlags: ["--refresh", "--json"])
        try requireNoPositionals(parsed, usage: "usage: tertia timetable [--club 39] [--date YYYY-MM-DD] [--period all|morning|afternoon|evening] [--search q] [--refresh] [--json]")
        let clubId = try parsed.values["--club"].map { raw in
            guard let id = Int(raw), id > 0 else { throw CLIError.usage("Invalid club ID '\(raw)'.") }
            return id
        }
        let (snap, date, items) = try await queryTimetable(clubId: clubId, date: parsed.values["--date"], period: parsed.values["--period"], search: parsed.values["--search"], refresh: parsed.flags.contains("--refresh"), store: store, client: client)

        if parsed.flags.contains("--json") {
            struct CLIOutput: Encodable { let clubId: Int; let clubName, clubShortCode, date: String; let classes: [ClassSession] }
            print(encodePrettyJSON(CLIOutput(clubId: snap.clubId, clubName: snap.clubName, clubShortCode: snap.clubShortCode, date: date, classes: items)))
            return
        }
        print("TERTIA · \(snap.clubName.uppercased()) · \(date) (\(items.count) classes)\n" + String(repeating: "-", count: 84))
        for item in items {
            let trainer = (item.trainer.isEmpty ? "Instructor TBA" : item.trainer).padding(toLength: 18, withPad: " ", startingAt: 0)
            let status = LondonCalendar.bookingWindowStatus(for: item).badgeLabel
            print("\(padLeft(item.id, width: 7))  \(item.startTime)-\(item.endTime) (\(padLeft(item.durationMinutes, width: 2))m)  \(item.title.padding(toLength: 30, withPad: " ", startingAt: 0))  \(trainer)  [\(status)]")
        }
    }

    private static func runClubs(args: [String], store: SharedStateStore, keychain: KeychainStore) throws {
        let parsed = try parseOptions(args, boolFlags: ["--all", "--json"])
        try requireNoPositionals(parsed, usage: "usage: tertia clubs [--all] [--json]")
        let (clubs, warning) = parsed.flags.contains("--all") ? (store.signedOutClubCatalog(), nil) : try availableClubsWithWarning(store: store, keychain: keychain)
        if let warning { writeStderr("warning: \(warning.localizedDescription)") }
        if parsed.flags.contains("--json") { print(encodePrettyJSON(clubs)); return }
        for c in clubs { print("\(padLeft(c.id, width: 3))  \(c.shortCode.padding(toLength: 10, withPad: " ", startingAt: 0))  \(c.name)") }
    }

    private static func runSetClub(args: [String], store: SharedStateStore, keychain: KeychainStore, client: PublicTimetableClient, onStateChanged: @Sendable () -> Void) async throws {
        let usage = "usage: tertia set-club <club_id> (must be available in `tertia clubs`)"
        let clubId = try singlePositiveInt(try parseOptions(args), usage: usage)
        guard let (club, warning) = try await applyWidgetClub(clubId: clubId, store: store, keychain: keychain, client: client, onStateChanged: onStateChanged) else {
            throw CLIError.usage(usage)
        }
        print("Widget club set to \(club.name) (id=\(club.id))")
        if let warning { writeStderr("warning:\(warning)") }
    }

    private static func runLogin(args: [String], store: SharedStateStore, keychain: KeychainStore, client: PublicTimetableClient, bookingClient: MobileBookingClient, onStateChanged: @Sendable () -> Void) async throws {
        let parsed = try parseOptions(args, valueFlags: ["--email"], boolFlags: ["--password-stdin"])
        try requireNoPositionals(parsed, usage: "usage: tertia login --email <email> [--password-stdin]")
        guard let email = parsed.values["--email"]?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            throw CLIError.usage("usage: tertia login --email <email> [--password-stdin]")
        }
        let password: String
        if parsed.flags.contains("--password-stdin") {
            password = try readBoundedPasswordStdin()
        } else if let envPass = ProcessInfo.processInfo.environment["TERTIA_PASSWORD"], !envPass.isEmpty {
            password = envPass
        } else {
            #if canImport(Darwin) || canImport(Glibc)
            guard isatty(STDIN_FILENO) != 0, let cPass = getpass("Password: ") else {
                throw CLIError.usage("Password required (pass --password-stdin or set TERTIA_PASSWORD).")
            }
            password = String(cString: cPass)
            #else
            throw CLIError.usage("Password required (pass --password-stdin or set TERTIA_PASSWORD).")
            #endif
        }
        guard !password.isEmpty else { throw CLIError.usage("Password cannot be empty.") }

        let started = try store.beginLogin(keychain: keychain)
        if let warning = started.warning { writeStderr("warning: \(warning.localizedDescription)") }
        let session = try await bookingClient.login(email: email, password: password)
        let committed: (cacheError: Error?, warning: KeychainError?)
        do { committed = try store.commitLogin(session, attempt: started.attempt, keychain: keychain) } catch {
            if case .previousSessionLost? = error as? KeychainError { onStateChanged() } // the old credential is gone
            throw error
        }
        var catalog = store.publicClubCatalog()
        var notes = [committed.cacheError.map { " Clearing the previous account's cached bookings failed: \($0.localizedDescription)." },
                     committed.warning.map { " \($0.localizedDescription)" }].compactMap { $0 }
        do {
            let aligned = try store.alignPreferencesToCurrentAccount(keychain: keychain)
            catalog = aligned.catalog
            notes.append(mirrorWarning(aligned.mirrorError))
            switch aligned.alignment {
            case .realigned(let next): _ = try? await client.fetchSchedule(clubId: next.clubId, date: LondonCalendar.londonTodayIso(), forceRefresh: false)
            case .noneEntitled: notes.append(" No timetable clubs available on this membership.")
            case .unchanged: break
            }
        } catch { notes.append(" Saving the widget club failed: \(error.localizedDescription).") }
        onStateChanged() // the Keychain credential changed, whatever the bookings sync does next
        let snap: BookingsSnapshot
        do {
            let synced = try await bookingClient.syncBookings(for: session, store: store, keychain: keychain)
            snap = synced.snapshot; notes.append(mirrorWarning(synced.mirrorError))
            onStateChanged()
        } catch where BookingClientError.isUnauthorized(error) {
            let expiry = store.expireSession(for: session, keychain: keychain)
            if expiry.didMutateDisk { onStateChanged() }
            throw CLIError.usage("Third Space rejected the new session token while syncing bookings. \(expiry.summary)")
        } catch {
            throw CLIError.usage("Signed in as \(session.email), but syncing bookings failed: \(error.localizedDescription)" + notes.joined())
        }
        // The same upcoming filter as `memberBookings`, at the clock after the sync, so a class that started meanwhile is not counted.
        let upcomingCount = snap.bookings.filter { !isKnownPastStart($0, now: Date()) }.count
        print("Signed in as \(session.name) (\(session.email)). Synced \(upcomingCount) future classes. Clubs: \(session.entitledClubs(from: catalog).map(\.name).joined(separator: ", "))" + notes.joined())
    }

    /// Reads a `--password-stdin` password: at most `maxBytes` bytes after stripping the one line ending a shell pipe
    /// adds (`\r\n` or `\n`; any other leading or trailing characters are the password). Reads in small chunks and stops
    /// once the input is provably too long, so oversized stdin is never buffered whole. Strict UTF-8; empty is refused
    /// by the caller. Swift treats "\r\n" as one Character, so the line ending is stripped on raw bytes before decoding.
    public static func readBoundedPasswordStdin(from handle: FileHandle = .standardInput, maxBytes: Int = 4096) throws -> String {
        let tooLong = CLIError.usage("Password input exceeds maximum length (\(maxBytes) bytes).")
        var bytes = Data()
        // Up to 2 line-ending bytes may be stripped, so `maxBytes + 3` bytes already prove the input too long.
        while bytes.count < maxBytes + 3, let chunk = try handle.read(upToCount: min(1024, maxBytes + 3 - bytes.count)), !chunk.isEmpty { bytes.append(chunk) }
        guard bytes.count <= maxBytes + 2 else { throw tooLong }
        if bytes.count >= 2 && bytes[bytes.endIndex - 2] == 0x0D && bytes[bytes.endIndex - 1] == 0x0A { bytes.removeLast(2) }
        else if bytes.last == 0x0A { bytes.removeLast() }
        guard bytes.count <= maxBytes else { throw tooLong }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { throw CLIError.usage("Password input is not valid UTF-8.") }
        return decoded
    }

    private static func runBookings(args: [String], store: SharedStateStore, keychain: KeychainStore, bookingClient: MobileBookingClient, onStateChanged: @Sendable () -> Void) async throws {
        let parsed = try parseOptions(args, boolFlags: ["--refresh", "--json"])
        try requireNoPositionals(parsed, usage: "usage: tertia bookings [--refresh] [--json]")
        let (session, snap, warning) = try await memberBookings(refresh: parsed.flags.contains("--refresh"), store: store, keychain: keychain, bookingClient: bookingClient, onStateChanged: onStateChanged)
        if let warning { writeStderr("warning:\(warning)") }
        if parsed.flags.contains("--json") { print(encodePrettyJSON(snap)); return }
        print("TERTIA · BOOKINGS FOR \(session.name.uppercased()) (\(snap.bookings.count) items)\n" + String(repeating: "-", count: 76))
        for item in snap.bookings {
            print("\(padLeft(item.id, width: 7))  \(item.startDate)  \(item.title.padding(toLength: 26, withPad: " ", startingAt: 0))  [\(item.eventAction.uppercased())]")
        }
    }

    public static let usageText = """
    tertia - Third Space timetable, booking CLI & MCP server

    Commands:
      tertia timetable [--club 39] [--date YYYY-MM-DD] [--period all|morning|afternoon|evening] [--search q] [--refresh] [--json]
      tertia clubs [--all] [--json]
      tertia set-club <club_id>
      tertia login --email <email> [--password-stdin]
      tertia logout
      tertia bookings [--refresh] [--json]
      tertia book <class_id>
      tertia cancel <class_id> [--late]
      tertia mcp
      tertia version
    """
}
