import Foundation
#if os(Windows)
import WinSDK
#endif

public struct HTTPHeader: Sendable, Equatable {
    public let name, value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public struct MobileRequest: Sendable, Equatable {
    public let method, url: String
    public let headers: [HTTPHeader]
    public let body: String?

    public init(method: String, url: String, headers: [HTTPHeader], body: String? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.body = body
    }
}

public enum BookingClientError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized(String)
    case apiError(status: Int, message: String)
    case transportError(String)
    case invalidResponse
    /// The Keychain account changed or signed out while the request was in flight; its result was discarded.
    case sessionSuperseded
    /// A book, cancel, or sign-in invalidated the cached bookings while this refresh was in flight; its result was discarded.
    case staleRefresh

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let msg), .transportError(let msg), .apiError(_, let msg): return msg
        case .invalidResponse: return "Unexpected response from Third Space API."
        case .sessionSuperseded: return "The signed-in account changed while the request was in flight; its result was discarded."
        case .staleRefresh: return "Bookings changed while the refresh was in flight; its result was discarded. Refresh again."
        }
    }

    public static func isUnauthorized(_ error: Error?) -> Bool {
        if case .unauthorized? = error as? BookingClientError { true } else { false }
    }
}

/// Authenticated booking client matching the Third Space Android 6.7.4 wire profile in
/// `Scripts/Fixtures/android-6.7.4-wire-profile.json` (headers, TLS ciphers and curves, ALPN `h2`).
public struct MobileBookingClient: Sendable {
    public typealias Transport = @Sendable (MobileRequest) async throws -> (status: Int, data: Data)
    /// Runs the synchronous credential handoff (launching the request and passing it the token) only while the session
    /// is still current, holding the account lock for the whole handoff; throwing stops the request before it leaves.
    /// The gate passes `handoff` the request to send, rebuilt from state it checked under the lock (a cancellation's
    /// late flag), so the bytes that leave always match the final authorization.
    public typealias HandoffGate = @Sendable (_ request: MobileRequest, _ handoff: (MobileRequest) throws -> Void) throws -> Void

    /// The gate of the request being sent; transports pass their handoff through `performHandoff`.
    @TaskLocal static var handoffGate: HandoffGate?
    /// `true` only during `send`'s early gate check, which launches nothing; a mutation gate changes no state there.
    @TaskLocal static var isPreflight = false

    /// Runs `handoff` with the final request through the current request's gate (`request` itself when there is none).
    /// `curlTransport` launches curl and writes its config inside it; a custom transport calls it before awaiting its
    /// response and sends the request it receives.
    public static func performHandoff(_ request: MobileRequest, _ handoff: (MobileRequest) throws -> Void) throws {
        if let gate = handoffGate { try gate(request, handoff) } else { try handoff(request) }
    }

    /// The curl command and its parent-side deadline; tests override them (for example a 0.5 s timeout).
    public struct CommandHooks: Sendable {
        public var executablePath: String
        public var arguments: [String]
        public var timeoutSeconds: TimeInterval
        /// Largest stdout or stderr a response may produce before the request fails and curl is stopped.
        public var maxOutputBytes: Int = 4 * 1024 * 1024
        /// Monotonic clock for the deadline (tests inject one).
        public var uptime: @Sendable () -> TimeInterval = SharedStateStore.systemUptime

        public init(executablePath: String = MobileBookingClient.resolveCurlExecutablePath(), arguments: [String] = ["--disable", "--config", "-"], timeoutSeconds: TimeInterval = 20,
                    maxOutputBytes: Int = 4 * 1024 * 1024, uptime: @escaping @Sendable () -> TimeInterval = SharedStateStore.systemUptime) {
            self.executablePath = executablePath; self.arguments = arguments; self.timeoutSeconds = timeoutSeconds; self.maxOutputBytes = maxOutputBytes; self.uptime = uptime
        }

        public static let live = CommandHooks()
    }

    public static let defaultBaseURL = "https://api.thirdspace-london.app"
    public static let apiVersion = "2.0"
    public static let platform = "android"
    public static let appVersion = "6.7.4"
    public static let userAgent = "okhttp/4.12.0"
    public static let tlsCiphers =
        "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:" +
        "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:" +
        "ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305:" +
        "ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA"
    public static let tlsCurves = "X25519:P-256:P-384"

    public let baseURL: String
    private let transport: Transport

    public init(baseURL: String = MobileBookingClient.defaultBaseURL, transport: @escaping Transport = MobileBookingClient.curlTransport) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.transport = transport
    }

    public func login(email: String, password: String) async throws -> MemberSession {
        struct Body: Encodable { let email, password: String }
        struct RawClub: Decodable { let id, clubId: Int?; let name, short_code, code: String? }
        struct RawLogin: Decodable {
            let token, name, email, homeClubName, expiresAt: String?
            let id, homeClubId: Int?
            let clubs: [RawClub]?
        }

        let loginEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyJSON = try Self.encodeJSON(Body(email: loginEmail, password: password))
        let data = try await send(method: "POST", path: "/api/v2/member/auth/login", query: "", token: nil, body: bodyJSON, fallbackError: "Sign-in failed.")
        guard let decoded = try? JSONDecoder().decode(RawLogin.self, from: data), let token = decoded.token, !token.isEmpty else {
            throw BookingClientError.apiError(status: 200, message: extractErrorMessage(from: data, fallback: "Sign-in did not return a session token."))
        }
        let accountClubs: [Club] = (decoded.clubs ?? []).compactMap { raw in
            guard let cid = raw.id ?? raw.clubId, cid > 0,
                  let cname = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines), !cname.isEmpty
            else { return nil }
            return Club(id: cid, name: cname, shortCode: (raw.short_code ?? raw.code ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let returnedEmail = decoded.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MemberSession(
            token: token, id: decoded.id ?? 0, name: decoded.name ?? loginEmail, email: returnedEmail.isEmpty ? loginEmail : returnedEmail,
            homeClubId: decoded.homeClubId ?? 0, homeClubName: decoded.homeClubName ?? "", expiresAt: decoded.expiresAt ?? "", clubs: accountClubs
        )
    }

    public func fetchBookings(token: String, gate: HandoffGate? = nil) async throws -> [MemberBooking] {
        struct RawClass: Decodable { let id: Int; let name, startDate, clubName, trainerName, eventAction: String?; let waitListPosition: Int? }
        struct RawResponse: Decodable { let classes: [RawClass]? }

        let query = "&Limits.Count=100&Range=future&Cancelled=false&ExcludeWaitingOnly=false"
        let data = try await send(method: "GET", path: "/api/v2/member/classes", query: query, token: token, body: nil, fallbackError: "Could not load member bookings.", gate: gate)
        guard let rawList = (try? JSONDecoder().decode(RawResponse.self, from: data))?.classes else {
            throw BookingClientError.invalidResponse
        }
        return rawList.map {
            MemberBooking(id: $0.id, title: $0.name ?? "Class", startDate: $0.startDate ?? "", clubName: $0.clubName ?? "", trainerName: $0.trainerName ?? "", eventAction: $0.eventAction ?? "", waitListPosition: $0.waitListPosition)
        }
    }

    /// Fetches bookings only while the Keychain holds `session` and commits them only if no account change or other
    /// mutation happened while the request was in flight (see `SharedStateStore.commitSyncedBookings`). `mirrorError`
    /// reports a failed widget-mirror write after the primary files committed.
    public func syncBookings(for session: MemberSession, store: SharedStateStore, keychain: KeychainStore) async throws -> (snapshot: BookingsSnapshot, mirrorError: Error?) {
        try await syncBookings(for: session, store: store, keychain: keychain, completingMutation: false)
    }

    /// `completingMutation` is set only by `mutateAndSync` for its own post-acceptance sync.
    func syncBookings(for session: MemberSession, store: SharedStateStore, keychain: KeychainStore, completingMutation: Bool) async throws -> (snapshot: BookingsSnapshot, mirrorError: Error?) {
        let startedAt = Date()
        let started = try store.beginBookingsSync(for: session, keychain: keychain, completingMutation: completingMutation)
        let list = try await fetchBookings(token: session.token, gate: Self.activeTokenGate(session, store: store, keychain: keychain))
        return try store.commitSyncedBookings(list, for: session, startedAtRevision: started.startedAtRevision, syncSeq: started.syncSeq, syncedAt: startedAt,
                                              keychain: keychain, completingMutation: completingMutation)
    }

    public func bookClass(classId: Int, token: String, gate: HandoffGate? = nil) async throws {
        struct Body: Encodable { let classId: Int }
        try await sendAction(method: "POST", path: "/api/v2/member/classes/book_class", token: token, body: try Self.encodeJSON(Body(classId: classId)), fallbackError: "Booking failed.", gate: gate)
    }

    public func cancelClass(classId: Int, lateBooking: Bool, token: String, gate: HandoffGate? = nil) async throws {
        try await sendAction(method: "PUT", path: "/api/v2/member/classes/cancel_booking", token: token, body: try Self.cancelBody(classId: classId, lateBooking: lateBooking),
                             fallbackError: "Cancellation failed.", gate: gate)
    }

    /// `{"classId":N,"lateBooking":flag}`, the one cancel body for dispatch and the handoff-time rebuild.
    private static func cancelBody(classId: Int, lateBooking: Bool) throws -> String {
        struct Body: Encodable { let classId: Int; let lateBooking: Bool }
        return try encodeJSON(Body(classId: classId, lateBooking: lateBooking))
    }

    /// Gate that runs the handoff under `.account.lock` and throws `.sessionSuperseded` once the Keychain no longer holds `session`.
    static func activeTokenGate(_ session: MemberSession, store: SharedStateStore, keychain: KeychainStore) -> HandoffGate {
        { request, handoff in try store.withAuthorizedTransportHandoff(for: session, keychain: keychain) { _ in try handoff(request) } }
    }

    /// What happened after an accepted book or cancel whose follow-up sync failed.
    public enum PostMutationFollowUp: Sendable {
        /// A 401 expired the session.
        case sessionExpired(SessionExpiryOutcome)
        /// Any other failure: what happened to the cached bookings.
        case cacheCleanup(FollowUpCleanupOutcome)
    }

    /// Result of an accepted book or cancel. `mirrorError` reports a failed widget-mirror write after the primary files
    /// committed.
    public enum MutationOutcome: Sendable {
        case synced(BookingsSnapshot, mirrorError: Error?)
        case acceptedRefreshFailed(Error, followUp: PostMutationFollowUp)
    }

    /// Books or cancels under `.mutation.lock`. Every gate pass (the early check, then the launch inside the transport)
    /// runs `authorize` under the account lock on the live session, its valid cached bookings, and the store
    /// (`SharedStateStore.withAuthorizedMutationHandoff`), and the cancel body carries the late flag of that check. A
    /// replaced session, or a class that started or crossed into the 3-hour window unconfirmed while waiting, sends zero
    /// requests and leaves the cached bookings valid. Only the launch pass, after its final `authorize`, marks the cache
    /// invalid before the request leaves; any failure from that point on (including a failed invalidation write)
    /// invalidates it again (the server may have applied it), while a failure before it (a refusal, or a Keychain or
    /// file read error before authorization completed) sent nothing and leaves valid bookings intact. A transport that
    /// failed or returned without entering its launch gate counts as dispatched. Acceptance advances the account
    /// revision before the follow-up sync, so no refresh begun earlier can commit, and no other refresh can commit while
    /// `.mutation.lock` is held.
    public func mutateAndSync(classId: Int, isCancel: Bool, session: MemberSession, store: SharedStateStore, keychain: KeychainStore,
                              authorize: @escaping @Sendable (MemberSession, BookingsSnapshot?, SharedStateStore) throws -> Bool) async throws -> MutationOutcome {
        try await store.withMutationLock(classId: classId) {
            // A transport that threw (or returned) after the early check passed but before entering its launch gate is
            // unaccounted for: it may have sent the request, so it counts as dispatched.
            let mayHaveDispatched = Flag(), preflightPassed = Flag(), launchEntered = Flag()
            let gate: HandoffGate = { request, handoff in
                let preflight = Self.isPreflight
                if !preflight { launchEntered.set() }
                try store.withAuthorizedMutationHandoff(for: session, keychain: keychain, dispatching: !preflight, onWillDispatch: mayHaveDispatched.set,
                                                        authorize: authorize) { late in
                    try handoff(isCancel ? MobileRequest(method: request.method, url: request.url, headers: request.headers,
                                                         body: try Self.cancelBody(classId: classId, lateBooking: late)) : request)
                }
                if preflight { preflightPassed.set() }
            }
            do {
                // The gate rebuilds the cancel body with the authorized late flag before anything is sent.
                if isCancel { try await cancelClass(classId: classId, lateBooking: false, token: session.token, gate: gate) }
                else { try await bookClass(classId: classId, token: session.token, gate: gate) }
            } catch {
                if mayHaveDispatched.value || (preflightPassed.value && !launchEntered.value) {
                    store.ensureBookingsInvalidatedAfterFailedDispatch(for: session, keychain: keychain)
                }
                throw error
            }
            do { try store.markMutationAccepted(for: session, keychain: keychain) }
            catch BookingClientError.sessionSuperseded { return .acceptedRefreshFailed(BookingClientError.sessionSuperseded, followUp: .cacheCleanup(.superseded)) }
            catch { return .acceptedRefreshFailed(error, followUp: .cacheCleanup(.failed(error.localizedDescription))) }
            do {
                let synced = try await syncBookings(for: session, store: store, keychain: keychain, completingMutation: true)
                return .synced(synced.snapshot, mirrorError: synced.mirrorError)
            } catch {
                if BookingClientError.isUnauthorized(error) {
                    return .acceptedRefreshFailed(error, followUp: .sessionExpired(store.expireSession(for: session, keychain: keychain)))
                }
                return .acceptedRefreshFailed(error, followUp: .cacheCleanup(store.invalidateBookingsForFailedFollowUp(for: session, keychain: keychain)))
            }
        }
    }

    /// One-way flag shared with `@Sendable` gate closures.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var isSet = false
        func set() { lock.lock(); isSet = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return isSet }
    }

    private func sendAction(method: String, path: String, token: String, body: String, fallbackError: String, gate: HandoffGate?) async throws {
        struct ActionResponse: Decodable { let statusCode: String? }
        let data = try await send(method: method, path: path, query: "", token: token, body: body, fallbackError: fallbackError, gate: gate)
        guard let statusCode = (try? JSONDecoder().decode(ActionResponse.self, from: data))?.statusCode else {
            throw BookingClientError.invalidResponse
        }
        if statusCode != "accepted" {
            throw BookingClientError.apiError(status: 200, message: extractErrorMessage(from: data, fallback: "\(fallbackError) (\(statusCode))"))
        }
    }

    private func send(method: String, path: String, query: String, token: String?, body: String?, fallbackError: String, gate: HandoffGate? = nil) async throws -> Data {
        let url = "\(baseURL)\(path)?api-version=\(Self.apiVersion)\(query)"
        var headers = [
            HTTPHeader(name: "User-Agent", value: Self.userAgent),
            HTTPHeader(name: "Accept-Encoding", value: "gzip"),
            HTTPHeader(name: "x-app-platform", value: Self.platform),
            HTTPHeader(name: "x-app-version", value: Self.appVersion),
        ]
        if let token, !token.isEmpty { headers.append(HTTPHeader(name: "x-fisikal-token", value: token)) }
        if body != nil { headers.append(HTTPHeader(name: "Content-Type", value: "application/json")) }

        // Early check through the gate (a superseded session or a denied action launches nothing); the transport gets the
        // request as the gate rebuilt it and must pass it through the gate once more at launch (`performHandoff`). A
        // transport that skipped that launch pass is never trusted: its result is discarded as a transport error.
        var request = MobileRequest(method: method, url: url, headers: headers, body: body)
        if let gate { try Self.$isPreflight.withValue(true) { try gate(request) { request = $0 } } }
        let checked = request, launched = Flag()
        let launchGate: HandoffGate? = gate.map { gate in { @Sendable request, handoff in try gate(request, handoff); launched.set() } }
        let (status, data) = try await Self.$handoffGate.withValue(launchGate) { try await transport(checked) }
        guard gate == nil || launched.value else { throw Self.ungatedLaunch }
        if (200..<300).contains(status) { return data }
        let fields = Self.errorFields(from: data)
        if status == 401 { throw BookingClientError.unauthorized(Self.errorMessage(fields, fallback: "Third Space session expired. Please sign in again.")) }
        let message = Self.errorMessage(fields, fallback: "\(fallbackError) (HTTP \(status))")
        // A 403 expires the session only for an explicit auth failure in any recognized error field; policy, quota, or
        // membership denials keep the login.
        if status == 403, let auth = Self.isAuthFailure403(message) ? message : (fields.errors + fields.topLevel).first(where: Self.isAuthFailure403) {
            throw BookingClientError.unauthorized(auth)
        }
        throw BookingClientError.apiError(status: status, message: message)
    }

    /// The error a transport produces when it returned a response without passing its launch gate.
    private static let ungatedLaunch = BookingClientError.transportError("The request was sent without passing its handoff gate.")

    private static let exactAuthClauses: Set<String> = [
        "token expired", "your token has expired", "expired token", "invalid token", "token is invalid",
        "session expired", "your session has expired", "unauthenticated", "authentication required",
    ]

    /// True only when a whole clause of `message` (split on `.`, `;`, `:`, `(`, `)`, `!`), lowercased, with internal
    /// whitespace collapsed and ASCII punctuation and whitespace trimmed, is exactly an auth-failure phrase, so
    /// `Invalid tokenization` or `token is not invalid` never expire a session.
    static func isAuthFailure403(_ message: String) -> Bool {
        message.split(whereSeparator: { ".;:()!".contains($0) }).contains { raw in
            let words = raw.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return exactAuthClauses.contains(words.trimmingCharacters(in: asciiPunctuationAndSpace))
        }
    }

    private static let asciiPunctuationAndSpace: CharacterSet = [0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E].reduce(into: .whitespacesAndNewlines) { set, range in
        set.insert(charactersIn: Unicode.Scalar(UInt8(range.lowerBound))...Unicode.Scalar(UInt8(range.upperBound)))
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return String(decoding: try enc.encode(value), as: UTF8.self)
    }

    /// Non-empty trimmed strings of the recognized error fields: `errors` (an object's string or string-array values
    /// in key order, or a string array) and the top-level `error`, `message`, and `title`.
    private static func errorFields(from data: Data) -> (errors: [String], topLevel: [String]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], []) }
        func strings(_ value: Any?) -> [String] {
            ((value as? [String]) ?? (value as? String).map { [$0] } ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let errors = (obj["errors"] as? [String: Any]).map { dict in dict.keys.sorted().flatMap { strings(dict[$0]) } } ?? strings(obj["errors"] as? [String])
        return (errors, ["error", "message", "title"].flatMap { strings(obj[$0] as? String) })
    }

    /// The first `errors` entry, else the first top-level field other than a bare `failed` or `invalid`.
    private func extractErrorMessage(from data: Data, fallback: String) -> String { Self.errorMessage(Self.errorFields(from: data), fallback: fallback) }

    private static func errorMessage(_ fields: (errors: [String], topLevel: [String]), fallback: String) -> String {
        fields.errors.first ?? fields.topLevel.first { $0 != "failed" && $0 != "invalid" } ?? fallback
    }

    /// Quotes a value for a curl config line scalar by scalar (so a `\r\n` pair escapes as `\\r\\n`); other control
    /// characters have no curl escape and are rejected.
    public static func escapeCurlConfig(_ value: String) throws -> String {
        try value.unicodeScalars.reduce(into: "") { out, scalar in
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                throw BookingClientError.transportError("Request contains an unsupported control character (U+\(String(scalar.value, radix: 16, uppercase: true))).")
            default: out.unicodeScalars.append(scalar)
            }
        }
    }

    /// Rejects CR, LF, and NUL in the method, URL, and headers (and `:` in header names) so no value can inject a line.
    public static func buildCurlConfig(_ request: MobileRequest) throws -> String {
        let fields = [request.method, request.url] + request.headers.flatMap { [$0.name, $0.value] }
        guard !fields.contains(where: { $0.unicodeScalars.contains { ["\r", "\n", "\0"].contains($0) } }),
              !request.headers.contains(where: { $0.name.isEmpty || $0.name.contains(":") })
        else { throw BookingClientError.transportError("Request contains an invalid method, URL, or header.") }
        var lines = [
            "url = \"\(try escapeCurlConfig(request.url))\"", "request = \"\(try escapeCurlConfig(request.method))\"",
            "compressed", "max-time = \"15\"", "silent", "show-error", "write-out = \"\\n%{http_code}\"", "header = \"Accept:\"",
        ]
        if request.url.hasPrefix("https://") {
            lines.append(contentsOf: ["http2", "tlsv1.2", "tls-max = \"1.3\"", "ciphers = \"\(tlsCiphers)\"", "curves = \"\(tlsCurves)\""])
        }
        lines.append(contentsOf: try request.headers.map { "header = \"\(try escapeCurlConfig("\($0.name): \($0.value)"))\"" })
        if let body = request.body { lines.append("data-raw = \"\(try escapeCurlConfig(body))\"") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Fixed system curl, never taken from the environment: `/usr/bin/curl` on macOS and other POSIX systems, the
    /// Windows system directory's `curl.exe` (`GetSystemDirectoryW`) on Windows.
    public static func resolveCurlExecutablePath() -> String {
        #if os(Windows)
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH))
        let length = Int(GetSystemDirectoryW(&buffer, UINT(buffer.count)))
        guard length > 0, length < buffer.count else { return "C:\\Windows\\System32\\curl.exe" }
        return String(decoding: buffer[..<length], as: UTF16.self) + "\\curl.exe"
        #else
        return "/usr/bin/curl"
        #endif
    }

    /// The parent environment without `TERTIA_PASSWORD` (so the child curl never sees the member's password) or
    /// `SSLKEYLOGFILE` (so TLS session keys are never written out), matched case-insensitively. On macOS
    /// `CURL_SSL_BACKEND` is pinned to `openssl` (the system curl's LibreSSL), so production and tests always negotiate
    /// with the same TLS backend whatever the parent set.
    public static func sanitizedCurlEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var clean = base.filter { !["TERTIA_PASSWORD", "SSLKEYLOGFILE"].contains($0.key.uppercased()) }
        #if os(macOS)
        clean["CURL_SSL_BACKEND"] = "openssl"
        #endif
        return clean
    }

    public static let curlTransport: Transport = makeCurlTransport(hooks: .live)

    public static func makeCurlTransport(hooks: CommandHooks) -> Transport {
        { request in
            let gate = handoffGate
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runCurlSync(request, hooks: hooks, gate: gate)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }

    /// Collects one pipe through `readabilityHandler` until EOF; `close()` stops collection and closes the handle
    /// under the same lock, so no handler touches a closed handle. More than `limit` bytes marks the drain `overflowed`
    /// and stops collection. Finishing (EOF, overflow, or close) runs `onEvent` exactly once (wakes the waiter).
    private final class PipeDrain: @unchecked Sendable {
        private let lock = NSLock(), handle: FileHandle, onEvent: @Sendable () -> Void
        private var buffer = Data(), finished = false, didOverflow = false

        init(_ handle: FileHandle, limit: Int, onEvent: @escaping @Sendable () -> Void) {
            self.handle = handle; self.onEvent = onEvent
            handle.readabilityHandler = { [self] h in
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                let chunk = h.availableData
                if chunk.isEmpty { finish(); return }
                buffer.append(chunk)
                if buffer.count > limit { didOverflow = true; buffer = Data(); finish(); try? handle.close() }
            }
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
        var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return didOverflow }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

        func close() {
            lock.lock(); defer { lock.unlock() }
            if !finished { finish() }
            try? handle.close()
        }

        /// Caller holds `lock`.
        private func finish() { finished = true; handle.readabilityHandler = nil; onEvent() }
    }

    private static let timedOut = BookingClientError.transportError("Network request timed out.")

    /// Writes `data` to a non-blocking descriptor, polling every 10 ms until done or `deadline` (monotonic uptime, checked
    /// before every write); never blocks past it, even when a child (or grandchild) holds the read end open without reading.
    /// Returns early, unwritten, once `shouldAbort` reports true (checked before every write).
    private static func writeAll(_ data: Data, to fd: Int32, deadline: TimeInterval, uptime: () -> TimeInterval, shouldAbort: () -> Bool) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let flags = fcntl(fd, F_GETFL)
        guard flags != -1, fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else { throw BookingClientError.transportError("Could not prepare the curl input pipe.") }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count, !shouldAbort() {
                guard uptime() < deadline else { throw timedOut }
                let n = write(fd, base + offset, raw.count - offset)
                if n > 0 { offset += n; continue }
                guard n == -1, errno == EAGAIN || errno == EINTR else { throw BookingClientError.transportError("Could not pass request to curl (errno \(errno)).") }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 10)
            }
        }
        #else
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        #endif
    }

    /// Runs curl with the config on stdin and a sanitized environment. One parent-side monotonic deadline, started before
    /// launch, covers the stdin write and the wait for exit (an expired deadline at launch launches nothing); stdout and
    /// stderr drain without blocking and are capped at `maxOutputBytes`. On expiry or overflow (which wakes the wait and
    /// stops a stalled stdin write at once, and wins over any other error) the handles close, the child gets SIGTERM then SIGKILL with bounded waits, and the request fails. The config
    /// is validated before the gate and rebuilt only when the request `gate` hands over differs, and launch plus the complete config write (then EOF) run inside `gate`, which holds the
    /// account lock, so a sign-out cannot interleave with the token handoff; the wait for the reply runs after it. The
    /// output must end with curl's `\n` plus a 3-digit HTTP status (100 to 599, one trailing CR allowed).
    public static func runCurlSync(_ request: MobileRequest, hooks: CommandHooks = .live, gate: HandoffGate? = nil) throws -> (status: Int, data: Data) {
        let initialConfig = try buildCurlConfig(request) // reject an invalid request before any lock or launch
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hooks.executablePath)
        proc.arguments = hooks.arguments
        proc.environment = sanitizedCurlEnvironment()
        let (inPipe, outPipe, errPipe) = (Pipe(), Pipe(), Pipe())
        proc.standardInput = inPipe; proc.standardOutput = outPipe; proc.standardError = errPipe
        let writer = inPipe.fileHandleForWriting
        defer { try? writer.close() }
        #if canImport(Darwin)
        guard fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw BookingClientError.transportError("Could not prepare the curl input pipe.") }
        #endif
        // `exited` reports only the child's exit (for the bounded kill path); `wake` fires on exit and whenever a drain
        // finishes (EOF or overflow), so the waiter re-checks state on every event.
        let exited = DispatchSemaphore(value: 0), wake = DispatchSemaphore(value: 0), didExit = Flag()
        proc.terminationHandler = { _ in didExit.set(); exited.signal(); wake.signal() }
        let out = PipeDrain(outPipe.fileHandleForReading, limit: hooks.maxOutputBytes, onEvent: { wake.signal() })
        let err = PipeDrain(errPipe.fileHandleForReading, limit: hooks.maxOutputBytes, onEvent: { wake.signal() })
        func forceStop() {
            out.close(); err.close()
            if proc.isRunning {
                proc.terminate()
                if exited.wait(timeout: .now() + 0.5) == .timedOut {
                    #if canImport(Darwin) || canImport(Glibc)
                    kill(proc.processIdentifier, SIGKILL)
                    #else
                    proc.terminate()
                    #endif
                    _ = exited.wait(timeout: .now() + 0.5)
                }
            }
        }
        let deadline = hooks.uptime() + hooks.timeoutSeconds
        var launched = false
        let handoff = { (final: MobileRequest) throws in
            let config = final == request ? initialConfig : try buildCurlConfig(final)
            guard hooks.uptime() < deadline else { throw timedOut }
            do { try proc.run() } catch { throw BookingClientError.transportError("Could not launch curl: \(error.localizedDescription)") }
            launched = true
            try writeAll(Data(config.utf8), to: writer.fileDescriptor, deadline: deadline, uptime: hooks.uptime, shouldAbort: { out.overflowed || err.overflowed })
            try? writer.close()
        }
        let tooLarge = BookingClientError.transportError("Response exceeded maximum size (\(hooks.maxOutputBytes) bytes).")
        do { if let gate { try gate(request, handoff) } else { try handoff(request) } } catch {
            if launched { forceStop() } else { out.close(); err.close() }
            throw out.overflowed || err.overflowed ? tooLarge : error
        }
        // An overflow on either pipe fails at once, even while the other pipe is still held open by a grandchild.
        while true {
            if out.overflowed || err.overflowed { forceStop(); throw tooLarge }
            if didExit.value && out.isFinished && err.isFinished { break }
            guard hooks.uptime() < deadline else { forceStop(); throw timedOut }
            _ = wake.wait(timeout: .now() + max(0, deadline - hooks.uptime()))
        }

        guard proc.terminationStatus == 0 else {
            let errText = String(decoding: err.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw BookingClientError.transportError(errText.isEmpty ? "Network request failed (exit \(proc.terminationStatus))." : errText)
        }
        let rawOut = out.data
        guard let lastNewline = rawOut.lastIndex(of: 0x0A) else { throw BookingClientError.invalidResponse }
        var trailer = rawOut[rawOut.index(after: lastNewline)...]
        if trailer.last == 0x0D { trailer = trailer.dropLast() }
        guard trailer.count == 3, trailer.allSatisfy({ (0x30...0x39).contains($0) }),
              let status = Int(String(decoding: trailer, as: UTF8.self)), (100...599).contains(status) else { throw BookingClientError.invalidResponse }
        return (status, Data(rawOut[..<lastNewline]))
    }
}
