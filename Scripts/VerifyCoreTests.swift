import AppKit
#if canImport(Darwin)
import Darwin
#endif
import Foundation
import SwiftUI
import TertiaCLI
import TertiaCore
import TertiaUI

// MARK: - Assertions and fixtures

struct AssertionFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String
    var errorDescription: String? { description }
}

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected { throw AssertionFailure(description: "FAIL: \(message) (expected \(expected), got \(actual))") }
}

func assertTrue(_ condition: Bool, _ message: String) throws {
    if !condition { throw AssertionFailure(description: "FAIL: \(message)") }
}

@MainActor func assertThrows(_ message: String, _ body: () async throws -> Void) async throws {
    do { try await body() } catch { return }
    throw AssertionFailure(description: "FAIL: \(message) (expected an error)")
}

/// The error text `body` throws ("" when it succeeds).
func denial(_ body: () throws -> Void) -> String {
    do { try body(); return "" } catch { return error.localizedDescription }
}

@MainActor func denialAsync(_ body: () async throws -> Void) async -> String {
    do { try await body(); return "" } catch { return error.localizedDescription }
}

extension Result {
    var error: Failure? { if case .failure(let e) = self { e } else { nil } }
}

/// Thread-safe mutable value shared with mock transports and background tasks.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

/// Per-club public timetable pages served by `MockTimetableURLProtocol` (no test ever reaches thirdspace.london).
private final class MockHTTPBox: @unchecked Sendable {
    static let shared = MockHTTPBox()
    struct Page { var status = 200; var body = ""; var delay = 0.0 }
    private let pages = Locked<[Int: Page]>([:])
    private let counts = Locked<[Int: Int]>([:])
    func set(_ clubId: Int, status: Int = 200, body: String, delay: Double = 0) { pages.mutate { $0[clubId] = Page(status: status, body: body, delay: delay) } }
    private let entryHooks = Locked<[Int: @Sendable () -> Void]>([:])
    /// Runs `hook` once, when the next request for `clubId` reaches the mock (its page is already chosen by then).
    func onEntry(_ clubId: Int, _ hook: @escaping @Sendable () -> Void) { entryHooks.mutate { $0[clubId] = hook } }
    func serve(_ clubId: Int) -> Page {
        counts.mutate { $0[clubId, default: 0] += 1 }
        let page = pages.value[clubId] ?? Page(status: 404, body: "")
        var hook: (@Sendable () -> Void)?
        entryHooks.mutate { hook = $0.removeValue(forKey: clubId) }
        hook?()
        return page
    }
    func count(_ clubId: Int) -> Int { counts.value[clubId] ?? 0 }
}

private final class MockTimetableURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url ?? URL(string: "https://www.thirdspace.london/timetable/")!
        let clubId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "location_id" }?.value.flatMap(Int.init) ?? 0
        let page = MockHTTPBox.shared.serve(clubId)
        DispatchQueue.global().asyncAfter(deadline: .now() + page.delay) {
            let resp = HTTPURLResponse(url: url, statusCode: page.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(page.body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

private func mockPublicClient(store: SharedStateStore) -> PublicTimetableClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [MockTimetableURLProtocol.self]
    return PublicTimetableClient(store: store, session: URLSession(configuration: cfg))
}

/// A London wall-clock slot `offset` seconds from now (minute precision), so fixtures stay valid at any run time.
struct Slot { let date, time: String; let start: Date }
/// A wall time inside the repeated autumn hour steps out of it in hour steps away from `now` (forward for a future
/// offset, backward for a past one), so a fixture always has one exact start on its own side of `now`.
func slot(_ offset: TimeInterval, from now: Date = Date()) -> Slot {
    var instant = now.addingTimeInterval(offset)
    while LondonCalendar.resolveLondonWallTime(dateIso: LondonCalendar.londonTodayIso(now: instant), hhmm: LondonCalendar.formatSyncTime(instant)) == .ambiguousRepeatedHour {
        instant.addTimeInterval(offset < 0 ? -3600 : 3600)
    }
    let date = LondonCalendar.londonTodayIso(now: instant), time = LondonCalendar.formatSyncTime(instant)
    return Slot(date: date, time: time, start: LondonCalendar.londonWallDate(dateIso: date, hhmm: time)!)
}

func expiryKind(_ outcome: SessionExpiryOutcome?) -> String {
    switch outcome {
    case .cleared?: "cleared"
    case .superseded?: "superseded"
    case .failed?: "failed"
    case nil: "none"
    }
}

struct Fx { let id: Int; let slot: Slot; let title: String; var club = "Canary Wharf" }

let canary = Club(id: 39, name: "Canary Wharf", shortCode: "CANARY")
let woodWharf = Club(id: 200, name: "Wood Wharf", shortCode: "WW")
let chelsea = Club(id: 220, name: "Chelsea", shortCode: "CHE")

func timetableHTML(_ classes: [Fx], emptyDays: [String] = [], clubs: [Club] = [canary, woodWharf, chelsea]) -> String {
    var days: [String: Any] = Dictionary(uniqueKeysWithValues: emptyDays.map { ($0, [Any]()) })
    for c in classes {
        var byClub = days[c.slot.date] as? [String: [[String: Any]]] ?? [:]
        let end = LondonCalendar.formatSyncTime(c.slot.start.addingTimeInterval(45 * 60))
        byClub[c.club, default: []].append(["id": c.id, "start_time": c.slot.time, "end_time": end, "service_title": c.title, "trainer_name": "Coach", "location_name": c.club, "duration_hours": 0, "duration_minutes": 45])
        days[c.slot.date] = byClub
    }
    func json(_ obj: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) }
    let clubsJSON = json(clubs.map { ["id": $0.id, "name": $0.name, "short_code": $0.shortCode, "hidden": false] as [String: Any] })
    return "<html><script>\nlet clubs = \(clubsJSON);\nlet timetable = \(json(days));\n</script></html>"
}

func loginJSON(token: String, id: Int, email: String) -> String {
    "{\"token\":\"\(token)\",\"id\":\(id),\"name\":\"Member \(id)\",\"email\":\"\(email)\",\"homeClubId\":39,\"homeClubName\":\"Canary Wharf\",\"expiresAt\":\"\",\"clubs\":[{\"id\":39,\"name\":\"Canary Wharf\"},{\"id\":200,\"name\":\"Wood Wharf\"}]}"
}

func classesJSON(_ items: [(Int, String)]) -> String {
    "{\"classes\":[" + items.map { "{\"id\":\($0.0),\"name\":\"Class \($0.0)\",\"startDate\":\"\($0.1)\",\"clubName\":\"Canary Wharf\",\"trainerName\":\"Coach\",\"eventAction\":\"cancel\"}" }.joined(separator: ",") + "]}"
}

func isoUTC(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// Scriptable mobile API: records every request and answers from mutable knobs.
private final class MobileMock: @unchecked Sendable {
    let requests = Locked<[MobileRequest]>([])
    let bookings = Locked<[String: String]>([:])     // token -> classes JSON
    let classesStatus = Locked<[String: Int]>([:])   // token -> HTTP status for /member/classes
    let classesDelay = Locked<[String: Double]>([:]) // token -> seconds
    let actionDelay = Locked<Double>(0)
    let actionStatus = Locked<(Int, String)>((200, "{\"statusCode\":\"accepted\"}"))
    let classesDelays = Locked<[Double]>([])         // per-request delays, consumed in order (they override classesDelay)
    let errorMessages = Locked<[String: String]>([:]) // token -> message of a non-200 /member/classes reply
    let classesArrived = DispatchSemaphore(value: 0)  // signalled when a /member/classes request arrives

    lazy var client = MobileBookingClient { [self] original in
        var req = original
        try MobileBookingClient.performHandoff(original) { req = $0 }
        requests.mutate { $0.append(req) }
        let token = req.headers.first { $0.name == "x-fisikal-token" }?.value ?? ""
        if req.url.contains("/auth/login") {
            if req.body?.contains("none@example.com") == true {
                return (200, Data("{\"token\":\"tok_N\",\"id\":9,\"name\":\"No Clubs\",\"email\":\"none@example.com\",\"homeClubId\":145,\"homeClubName\":\"Membership Only\",\"clubs\":[{\"id\":145,\"name\":\"Membership Only\"}]}".utf8))
            }
            let isB = req.body?.contains("b@example.com") == true
            return (200, Data(loginJSON(token: isB ? "tok_B" : "tok_A", id: isB ? 8 : 7, email: isB ? "b@example.com" : "a@example.com").utf8))
        }
        if req.url.contains("/member/classes?") {
            // The response is fixed when the request arrives, so a delayed reply carries the data of its start time.
            let status = classesStatus.value[token] ?? 200, body = bookings.value[token] ?? classesJSON([]), message = errorMessages.value[token] ?? "HTTP \(status)"
            var delay = classesDelay.value[token]
            classesDelays.mutate { if !$0.isEmpty { delay = $0.removeFirst() } }
            classesArrived.signal()
            if let delay { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            return (status, Data((status == 200 ? body : "{\"message\":\"\(message)\"}").utf8))
        }
        if actionDelay.value > 0 { try? await Task.sleep(nanoseconds: UInt64(actionDelay.value * 1e9)) }
        return (actionStatus.value.0, Data(actionStatus.value.1.utf8))
    }
    var count: Int { requests.value.count }
    var logins: Int { requests.value.filter { $0.url.contains("/auth/login") }.count }
    func actions(after index: Int) -> [MobileRequest] { requests.value.dropFirst(index).filter { !$0.url.contains("/member/classes?") } }
}

/// Waits off the main actor (at most `seconds`) for `signal`; `false` on timeout.
func waitFor(_ signal: DispatchSemaphore, seconds: Double = 3) async -> Bool {
    await withCheckedContinuation { cont in DispatchQueue.global().async { cont.resume(returning: signal.wait(timeout: .now() + seconds) == .success) } }
}

/// Blocks the calling thread (at most `seconds`) for `signal`, for synchronous seams such as a mock transport step.
func blockingWait(_ signal: DispatchSemaphore, seconds: Double) -> Bool { signal.wait(timeout: .now() + seconds) == .success }

/// Discards earlier signals so the next `waitFor` sees only a new event.
func drain(_ signal: DispatchSemaphore) { while signal.wait(timeout: .now()) == .success {} }

/// Runs a child in its own process group (`setpgrp`, then `exec`) with one deadline covering both its exit and its
/// output: the exit is watched independently of pipe EOF, a late child's group gets SIGTERM then SIGKILL, and a group
/// whose members still hold the pipes open past the deadline (a background grandchild of a child that already exited)
/// is killed too, so every call returns within about `timeoutSeconds` and leaves no owned descendant running.
/// `timedOut` is set when either the exit or the output drain missed the deadline. The child's own PID is cleared under
/// the lock in its termination handler, so nothing ever signals a reaped (and possibly reused) PID. stdout and stderr are
/// each capped at `maxOutputBytes`: the first stream past it closes both pipes, the group is killed at once, and the call
/// throws naming that stream.
private func runSubprocess(_ path: String, args: [String], env: [String: String]? = nil, stdin: FileHandle? = nil, timeoutSeconds: TimeInterval = 8,
                           maxOutputBytes: Int = 2 * 1024 * 1024) throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    proc.arguments = ["-e", "setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127", path] + args
    if let env { proc.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    if let stdin { proc.standardInput = stdin }
    let (outPipe, errPipe) = (Pipe(), Pipe())
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    let exited = DispatchSemaphore(value: 0), drained = DispatchGroup()
    // The live child (0 once reaped) and its process group (same ID, set once the child is started).
    let owned = Locked<(child: pid_t, group: pid_t)>((0, 0))
    proc.terminationHandler = { _ in owned.mutate { $0.child = 0 }; exited.signal() }
    /// Signals the child's group (descendants included) and, while it is not reaped, the child itself (its `setpgrp`
    /// may not have run yet), under the same lock the termination handler takes.
    @Sendable func stop(_ signal: Int32) { owned.mutate { if $0.group > 0 { kill(-$0.group, signal) }; if $0.child > 0 { kill($0.child, signal) } } }
    let outs = [Locked(Data()), Locked(Data())], overflow = Locked<String?>(nil)
    for (pipe, (box, stream)) in zip([outPipe, errPipe], zip(outs, ["stdout", "stderr"])) {
        drained.enter()
        let done = Locked(false)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            var over = false
            if !chunk.isEmpty { box.mutate { $0.append(chunk); over = $0.count > maxOutputBytes } }
            if !chunk.isEmpty && !over { return }
            handle.readabilityHandler = nil
            if over {
                overflow.mutate { $0 = $0 ?? stream }
                stop(SIGKILL)
            }
            var first = false
            done.mutate { first = !$0; $0 = true }
            if first { drained.leave() }
        }
    }
    try proc.run()
    let started = proc.processIdentifier
    // The group outlives a child that was already reaped (its termination handler ran first); the child's PID does not.
    owned.mutate {
        $0.group = started
        if exited.wait(timeout: .now()) == .success { exited.signal() } else { $0.child = started }
    }
    if overflow.value != nil { stop(SIGKILL) } // overflowed before the child was published
    let deadline = DispatchTime.now() + timeoutSeconds
    // Wait for exit, but stop early once a stream overflowed (the group is being killed).
    var exitTimedOut = true
    while DispatchTime.now() < deadline {
        if exited.wait(timeout: .now() + 0.05) == .success { exitTimedOut = false; break }
        if overflow.value != nil { break }
    }
    var didExit = !exitTimedOut
    if exitTimedOut {
        stop(SIGTERM)
        didExit = exited.wait(timeout: .now() + 1) == .success
        if !didExit { stop(SIGKILL); didExit = exited.wait(timeout: .now() + 1) == .success }
    }
    var drainTimedOut = false
    if overflow.value == nil, drained.wait(timeout: max(deadline, .now() + 0.2)) == .timedOut { drainTimedOut = true; stop(SIGKILL) }
    for pipe in [outPipe, errPipe] { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
    // Never block on an unkillable child: `waitUntilExit` runs only once its exit was observed.
    guard didExit else { throw AssertionFailure(description: "FAIL: \(path) survived SIGKILL past its deadline") }
    proc.waitUntilExit()
    if let stream = overflow.value { throw AssertionFailure(description: "FAIL: \(path) wrote more than \(maxOutputBytes) bytes to \(stream); the child was killed") }
    return (proc.terminationStatus, String(decoding: outs[0].value, as: UTF8.self), String(decoding: outs[1].value, as: UTF8.self), exitTimedOut || drainTimedOut)
}

/// Runs `body` with `fd` (stdout by default) redirected to a temp file and returns its exit code and written text; the
/// descriptor is restored even when `body` throws.
@MainActor func captureOutput(fd target: Int32 = STDOUT_FILENO, _ body: () async throws -> Int32) async throws -> (code: Int32, out: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tertia-capture-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw AssertionFailure(description: "FAIL: cannot create capture file") }
    defer { try? FileManager.default.removeItem(at: url) }
    fflush(stdout)
    let saved = dup(target)
    guard saved >= 0 else { throw AssertionFailure(description: "FAIL: dup(\(target)) failed (errno \(errno))") }
    let fd = open(url.path, O_WRONLY)
    guard fd >= 0 else { close(saved); throw AssertionFailure(description: "FAIL: open(capture file) failed (errno \(errno))") }
    guard dup2(fd, target) >= 0 else { close(fd); close(saved); throw AssertionFailure(description: "FAIL: dup2(capture, \(target)) failed (errno \(errno))") }
    close(fd)
    var code: Int32 = 0, thrown: Error?
    do { code = try await body() } catch { thrown = error }
    fflush(stdout)
    let restored = dup2(saved, target)
    close(saved)
    guard restored >= 0 else { throw AssertionFailure(description: "FAIL: restoring \(target) failed (errno \(errno))") }
    if let thrown { throw thrown }
    return (code, try String(contentsOf: url, encoding: .utf8))
}

/// Runs `body` with standard input read from a scratch file holding `input`; stdin is restored even when `body` throws.
@MainActor func withStdin<T>(_ ctx: TestContext, _ input: Data, _ body: () async throws -> T) async throws -> T {
    let file = ctx.scratch("stdin")
    try input.write(to: file)
    let saved = dup(STDIN_FILENO), fd = Darwin.open(file.path, O_RDONLY)
    guard saved >= 0, fd >= 0, dup2(fd, STDIN_FILENO) >= 0 else { throw AssertionFailure(description: "FAIL: stdin redirection setup") }
    close(fd)
    defer { dup2(saved, STDIN_FILENO); close(saved) }
    return try await body()
}

/// The python3 for the local TLS 1.3 + ALPN h2 test: test.sh's `TERTIA_RESOLVED_PYTHON`, else (a standalone run) the
/// one `publish.py print-test-python` selects (honoring `TERTIA_TEST_PYTHON`), so there is one selection rule.
private func testPython(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    if let resolved = environment["TERTIA_RESOLVED_PYTHON"], !resolved.isEmpty { return resolved }
    let res = try runSubprocess("/usr/bin/python3", args: ["-I", root.appendingPathComponent("Scripts/publish.py").path, "print-test-python"], env: environment, timeoutSeconds: 10)
    guard res.status == 0, !res.stdout.isEmpty else { throw AssertionFailure(description: "FAIL: the TLS 1.3 + ALPN h2 test needs a python3 with TLS 1.3 (\(res.stderr))") }
    return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeJSON(_ line: String?) throws -> [String: Any] {
    guard let line, let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
        throw AssertionFailure(description: "FAIL: invalid JSON-RPC output: \(line ?? "nil")")
    }
    return obj
}

/// A `tools/call` result: throws on a JSON-RPC error, or when `result` lacks the `isError` flag or a first `content`
/// item with `text`, so a protocol failure never reads as a successful empty tool result.
private func toolResult(_ line: String?) throws -> (isError: Bool, text: String) {
    let object = try decodeJSON(line)
    guard object["error"] == nil, let result = object["result"] as? [String: Any], let isError = result["isError"] as? Bool,
          let content = result["content"] as? [[String: Any]], let text = content.first?["text"] as? String else {
        throw AssertionFailure(description: "FAIL: not a tools/call result: \(line ?? "nil")")
    }
    return (isError, text)
}

private func errorCode(_ line: String?) throws -> Int? { (try decodeJSON(line)["error"] as? [String: Any])?["code"] as? Int }

/// A fresh scratch path under test.sh's `TERTIA_TEST_SCRATCH_ROOT` (removed by its cleanup even after a watchdog kill),
/// else under the temporary folder (a standalone run).
private func tempDir(_ name: String) -> URL {
    let root = ProcessInfo.processInfo.environment["TERTIA_TEST_SCRATCH_ROOT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    return (root ?? FileManager.default.temporaryDirectory).appendingPathComponent("tertia-\(name)-\(UUID().uuidString)", isDirectory: true)
}

/// Appends `service` to test.sh's `TERTIA_TEST_KEYCHAIN_LOG` (one synchronous append, before any item of it exists), so
/// test.sh's cleanup deletes the item even when this run is killed before its own cleanup.
func logKeychainService(_ service: String) {
    guard let path = ProcessInfo.processInfo.environment["TERTIA_TEST_KEYCHAIN_LOG"], !path.isEmpty else { return }
    let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard fd >= 0 else { return }
    defer { close(fd) }
    let line = Array((service + "\n").utf8)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

private func seedForeignKeychainItem(service: String, account: String) throws {
    logKeychainService(service)
    let res = try runSubprocess("/usr/bin/security", args: ["add-generic-password", "-s", service, "-a", account, "-w", "stale_from_other_binary"])
    try assertTrue(res.status == 0 && !res.timedOut, "seeded foreign-ACL Keychain item")
}

/// Seeds `bookings` through the real account API: the Keychain must already hold `session`.
func syncSeed(_ st: SharedStateStore, _ session: MemberSession, _ kc: KeychainStore, _ bookings: [MemberBooking], syncedAt: Date = Date()) throws {
    _ = try st.commitSyncedBookings(bookings, for: session, started: try st.beginBookingsSync(for: session, keychain: kc), syncedAt: syncedAt, keychain: kc)
}

/// Signs `session` in through `commitLogin`, then seeds its bookings.
func loginSeed(_ st: SharedStateStore, _ session: MemberSession, _ kc: KeychainStore, _ bookings: [MemberBooking]) throws {
    if let error = try st.commitLogin(session, keychain: kc).cacheError { throw error }
    try syncSeed(st, session, kc, bookings)
}

/// Clicks the button the menu draws for `row` (`classAction`, the callback `classCard` attaches) at `now` (the model's
/// fixed clock, else the current time), on the row's day: the menu shows that day first. Throws when the card is not a
/// button, so a disabled card is asserted with `classAction(...) == nil` instead.
@MainActor func click(_ vm: ScheduleViewModel, _ row: ClassSession, now: Date? = nil) async throws {
    vm.selectedDate = row.date
    guard let action = vm.classAction(for: row, now: now ?? vm.nowOverride ?? Date()) else {
        throw AssertionFailure(description: "FAIL: the card of class \(row.id) (\(row.date) \(row.startTime)) is not a button")
    }
    await action()
}

/// For a card that is not a button (asserted: `classAction` is `nil`), calls the click handler directly (defense in
/// depth) with the intent, account, club, row, and late confirmation the card shows, on the row's own day.
@MainActor func pressDisabled(_ vm: ScheduleViewModel, _ row: ClassSession, now: Date? = nil) async throws {
    vm.selectedDate = row.date
    try assertTrue(vm.classAction(for: row, now: now ?? vm.nowOverride ?? Date()) == nil, "the card of class \(row.id) is not a button")
    await vm.handleClassAction(classId: row.id, expectedCancel: vm.bookings?.bookedIds.contains(row.id) == true, expectedToken: vm.memberSession?.token ?? "",
                               expectedClubId: vm.preferences.clubId, title: row.title, startTime: row.startTime, expectedDate: row.date,
                               expectedConfirmedLate: vm.isConfirmingLateCancel(row.id))
}

/// Test fixtures that write state files verbatim, the way an older build or another process left them (the store's
/// own writers merge, prune, and validate, so they cannot produce every legacy or hostile state).
extension SharedStateStore {
    /// An unpaused sign-in: `beginLogin` and `commitLogin` back to back.
    @discardableResult
    func commitLogin(_ session: MemberSession, keychain: KeychainStore) throws -> (cacheError: Error?, warning: Error?) {
        let r = try commitLogin(session, attempt: try beginLogin(keychain: keychain).attempt, keychain: keychain); return (r.cacheError, r.warning)
    }

    /// Commits a refresh begun with `beginBookingsSync` (its revision and request number).
    func commitSyncedBookings(_ bookings: [MemberBooking], for session: MemberSession, started: (startedAtRevision: UInt64, syncSeq: UInt64), syncedAt: Date = Date(),
                              keychain: KeychainStore) throws -> (snapshot: BookingsSnapshot, mirrorError: Error?) {
        try commitSyncedBookings(bookings, for: session, startedAtRevision: started.startedAtRevision, syncSeq: started.syncSeq, syncedAt: syncedAt, keychain: keychain)
    }

    private func folders() -> [URL] {
        Mirror(reflecting: self).children.compactMap { ["primaryDirectory", "mirrorDirectory"].contains($0.label) ? $0.value as? URL : nil }
    }

    /// Writes `snapshot` to the primary and the mirror folder exactly as given (future stamps and all).
    func seedSnapshot(_ snapshot: TimetableSnapshot) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .custom { date, encoder in
            let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer(); try c.encode(fmt.string(from: date))
        }
        let data = try enc.encode(snapshot)
        for dir in folders() {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("snapshot-\(snapshot.clubId).json"), options: .atomic)
        }
    }

    func seedPreferences(_ preferences: TertiaPreferences) throws { try updatePreferences { $0 = preferences } }
}

// MARK: - Shared fixtures (computed once, at first use)

let canaryMember = MemberSession(token: "t", id: 1, name: "Alex Morgan", email: "a@b.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
let bookingsA = BookingsSnapshot(ownerKey: canaryMember.ownerKey!, bookings: [
    MemberBooking(id: 3064910, title: "Dynamic Reformer", startDate: "2026-11-22T10:00:00Z", clubName: "Canary Wharf", trainerName: "Fallon Stocker", eventAction: "CANCEL"),
    MemberBooking(id: 999, title: "Waitlist Yoga", startDate: "2026-11-22T12:00:00Z", clubName: "Canary Wharf", trainerName: "Sharon Saker", eventAction: "waitlist", waitListPosition: 2),
], syncedAt: Date())
let memberB = MemberSession(token: "tok_B", id: 8, name: "B", email: "b@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary])
/// A class inside the 3-hour late-cancel window on any run date: the first offset (2h, then 15-minute steps around it)
/// whose wall time is exact. The repeated autumn hour covers 2 real hours, so one of them always is, and `slot`
/// never has to move it out of the window. Deterministic-clock checks of that hour live in `loop7`.
let lateSlot: Slot = {
    let now = Date()
    let offset = [7200.0, 8100, 6300, 9000, 5400, 9900, 4500, 3600, 2700, 1800].first { offset in
        let instant = now.addingTimeInterval(offset)
        return LondonCalendar.resolveLondonWallTime(dateIso: LondonCalendar.londonTodayIso(now: instant), hhmm: LondonCalendar.formatSyncTime(instant)) != .ambiguousRepeatedHour
    } ?? 7200
    return slot(offset, from: now)
}()
let openSlot = slot(5 * 3600), farSlot = slot(60 * 3600), pastSlot = slot(-2 * 3600), hugeId = 9_007_199_254_740_993
let todayIso = LondonCalendar.londonTodayIso()
// A 00:01 class is checked with a fixed clock one hour after it starts, so the result never depends on run time.
let dawnSlot = Slot(date: todayIso, time: "00:01", start: LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "00:01")!)
let fixtures = [Fx(id: 501, slot: openSlot, title: "Open Reformer"), Fx(id: 502, slot: lateSlot, title: "Late Yoga"), Fx(id: 503, slot: farSlot, title: "Far Ride"),
                Fx(id: 504, slot: pastSlot, title: "Past Pump"), Fx(id: 505, slot: dawnSlot, title: "Dawn Ride")]
let page39 = timetableHTML(fixtures, emptyDays: (0...3).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) })
let memberA = MemberSession(token: "tok_A", id: 7, name: "A", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
let previewNow = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "06:00")!
let preview = SampleData.previewSnapshot(now: previewNow)
let dupStart = TimetableSnapshot(clubs: [], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: [
    ClassSession(id: 1, date: todayIso, startTime: "06:20", endTime: "07:00", durationMinutes: 40, title: "A", trainer: "", clubName: ""),
    ClassSession(id: 2, date: todayIso, startTime: "06:20", endTime: "07:00", durationMinutes: 40, title: "B", trainer: "", clubName: ""),
    ClassSession(id: 3, date: todayIso, startTime: "06:40", endTime: "07:00", durationMinutes: 20, title: "C", trainer: "", clubName: ""),
    ClassSession(id: 4, date: todayIso, startTime: "07:30", endTime: "08:00", durationMinutes: 30, title: "D", trainer: "", clubName: "")]], syncedAt: previewNow, daySyncedAt: [todayIso: previewNow])
let yesterdayOnly = TimetableSnapshot(clubs: [], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [LondonCalendar.addDays(to: todayIso, days: -1)!: []], syncedAt: previewNow)
@MainActor func signIn(_ vm: ScheduleViewModel, _ email: String = "a@example.com") async { vm.emailInput = email; vm.passwordInput = "x"; await vm.signIn() }
let open501 = ClassSession(id: 501, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Open Reformer", trainer: "", clubName: "Canary Wharf")
func activeBooking(_ id: Int, _ start: String) -> MemberBooking { MemberBooking(id: id, title: "Class \(id)", startDate: start, clubName: "Canary Wharf", trainerName: "", eventAction: "cancel") }

// MARK: - HTTP/2 (RFC 9113) frames and HPACK (RFC 7541), enough to read one curl request

/// RFC 7541 Appendix A static table (index 1...61), generated from golang.org/x/net/http2/hpack.
let hpackStatic: [(String, String)] = [
    (":authority", ""), (":method", "GET"), (":method", "POST"), (":path", "/"), (":path", "/index.html"), (":scheme", "http"),
    (":scheme", "https"), (":status", "200"), (":status", "204"), (":status", "206"), (":status", "304"), (":status", "400"),
    (":status", "404"), (":status", "500"), ("accept-charset", ""), ("accept-encoding", "gzip, deflate"), ("accept-language", ""), ("accept-ranges", ""),
    ("accept", ""), ("access-control-allow-origin", ""), ("age", ""), ("allow", ""), ("authorization", ""), ("cache-control", ""),
    ("content-disposition", ""), ("content-encoding", ""), ("content-language", ""), ("content-length", ""), ("content-location", ""), ("content-range", ""),
    ("content-type", ""), ("cookie", ""), ("date", ""), ("etag", ""), ("expect", ""), ("expires", ""),
    ("from", ""), ("host", ""), ("if-match", ""), ("if-modified-since", ""), ("if-none-match", ""), ("if-range", ""),
    ("if-unmodified-since", ""), ("last-modified", ""), ("link", ""), ("location", ""), ("max-forwards", ""), ("proxy-authenticate", ""),
    ("proxy-authorization", ""), ("range", ""), ("referer", ""), ("refresh", ""), ("retry-after", ""), ("server", ""),
    ("set-cookie", ""), ("strict-transport-security", ""), ("transfer-encoding", ""), ("user-agent", ""), ("vary", ""), ("via", ""),
    ("www-authenticate", ""),
]
/// RFC 7541 Appendix B code lengths per byte value; the code is canonical, so lengths alone rebuild it.
let hpackHuffmanLengths: [UInt8] = [
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10,
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6,
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23, 24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23, 21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25, 19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23, 26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
]

/// `(bit length << 32 | code) -> byte`, rebuilt canonically: codes ascend by (length, byte value).
let hpackHuffmanCodes: [UInt64: UInt8] = {
    var table: [UInt64: UInt8] = [:], code: UInt64 = 0, previous = 0
    for (i, symbol) in (0..<256).sorted(by: { (hpackHuffmanLengths[$0], $0) < (hpackHuffmanLengths[$1], $1) }).enumerated() {
        let length = Int(hpackHuffmanLengths[symbol])
        if i > 0 { code = (code + 1) << UInt64(length - previous) }
        previous = length
        table[UInt64(length) << 32 | code] = UInt8(symbol)
    }
    return table
}()

/// Decodes one header block into ordered (name, value) pairs; throws on anything malformed.
func hpackDecode(_ block: [UInt8]) throws -> [(String, String)] {
    var i = 0, dynamic: [(String, String)] = [], out: [(String, String)] = []
    let bad = AssertionFailure(description: "FAIL: malformed HPACK block")
    func integer(_ prefix: Int) throws -> Int {
        guard i < block.count else { throw bad }
        let mask = (1 << prefix) - 1
        var value = Int(block[i]) & mask; i += 1
        guard value == mask else { return value }
        var shift = 0
        while true {
            guard i < block.count, shift < 28 else { throw bad }
            let byte = block[i]; i += 1
            value += Int(byte & 0x7f) << shift; shift += 7
            if byte & 0x80 == 0 { return value }
        }
    }
    func string() throws -> String {
        guard i < block.count else { throw bad }
        let huffman = block[i] & 0x80 != 0, length = try integer(7)
        guard i + length <= block.count else { throw bad }
        let raw = Array(block[i..<(i + length)]); i += length
        guard huffman else { return String(decoding: raw, as: UTF8.self) }
        var decoded: [UInt8] = [], code: UInt64 = 0, bits = 0
        for byte in raw { for shift in stride(from: 7, through: 0, by: -1) {
            code = code << 1 | UInt64((byte >> UInt8(shift)) & 1); bits += 1
            if let symbol = hpackHuffmanCodes[UInt64(bits) << 32 | code] { decoded.append(symbol); code = 0; bits = 0 }
        } }
        guard bits < 8, code == (1 << UInt64(bits)) - 1 else { throw bad } // padding: fewer than 8 one bits
        return String(decoding: decoded, as: UTF8.self)
    }
    func entry(_ index: Int) throws -> (String, String) {
        if (1...hpackStatic.count).contains(index) { return hpackStatic[index - 1] }
        guard index > hpackStatic.count, index - hpackStatic.count - 1 < dynamic.count else { throw bad }
        return dynamic[index - hpackStatic.count - 1]
    }
    while i < block.count {
        let byte = block[i]
        if byte & 0x80 != 0 { out.append(try entry(try integer(7))) }
        else if byte & 0x40 != 0 {
            let index = try integer(6), field = (index == 0 ? try string() : try entry(index).0, try string())
            out.append(field); dynamic.insert(field, at: 0)
        } else if byte & 0x20 != 0 { _ = try integer(5) } // dynamic table size update
        else { let index = try integer(4); out.append((index == 0 ? try string() : try entry(index).0, try string())) }
    }
    return out
}

/// Reads a client connection: the 24-byte preface, then frames until the request stream ends. Returns the preface,
/// the HEADERS(+CONTINUATION) block without padding or priority, and the DATA payload.
func readHTTP2Request(_ conn: BoundedConnection) -> (preface: [UInt8], headerBlock: [UInt8], data: [UInt8]) {
    var buffer: [UInt8] = []
    func fill(_ count: Int) -> Bool {
        while buffer.count < count { guard let chunk = conn.read() else { return false }; buffer += chunk }
        return true
    }
    guard fill(24) else { return ([], [], []) }
    let preface = Array(buffer.prefix(24)); buffer.removeFirst(24)
    var headerBlock: [UInt8] = [], data: [UInt8] = []
    for _ in 0..<64 {
        guard fill(9) else { break }
        let length = Int(buffer[0]) << 16 | Int(buffer[1]) << 8 | Int(buffer[2]), type = buffer[3], flags = buffer[4]
        guard fill(9 + length) else { break }
        var payload = ArraySlice(buffer[9..<(9 + length)]); buffer.removeFirst(9 + length)
        if type == 0x0 || type == 0x1, flags & 0x08 != 0, let pad = payload.first { payload = payload.dropFirst().dropLast(Int(pad)) }
        if type == 0x1, flags & 0x20 != 0 { payload = payload.dropFirst(5) }
        if type == 0x1 || type == 0x9 { headerBlock += payload }
        if type == 0x0 { data += payload }
        if (type == 0x0 || type == 0x1), flags & 0x01 != 0 { break } // END_STREAM
    }
    return (preface, headerBlock, data)
}

/// A loopback listener on an ephemeral port.
func loopbackListener() throws -> (fd: Int32, port: Int) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard fd >= 0, bound == 0, Darwin.listen(fd, 1) == 0 else { throw AssertionFailure(description: "FAIL: loopback listener") }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) } }
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
}

/// Waits with `poll` for `events` on `fd` until the monotonic `deadline`; false on timeout or error.
func pollUntil(_ fd: Int32, _ events: Int32, deadline: TimeInterval) -> Bool {
    var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
    let ms = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
    return ms > 0 && poll(&pfd, 1, ms) == 1 && pfd.revents & Int16(events) != 0
}

/// One accepted loopback connection whose every read and write waits (with `poll`) only until the server deadline.
final class BoundedConnection: @unchecked Sendable {
    let fd: Int32, deadline: TimeInterval
    init(fd: Int32, deadline: TimeInterval) { self.fd = fd; self.deadline = deadline }

    /// Up to `limit` bytes; `nil` at EOF, on error, or at the deadline.
    func read(_ limit: Int = 4096) -> [UInt8]? {
        guard pollUntil(fd, POLLIN, deadline: deadline) else { return nil }
        var buf = [UInt8](repeating: 0, count: limit)
        let n = Darwin.read(fd, &buf, limit)
        return n > 0 ? Array(buf.prefix(n)) : nil
    }

    @discardableResult func write(_ bytes: [UInt8]) -> Bool {
        var rest = ArraySlice(bytes)
        while !rest.isEmpty {
            guard pollUntil(fd, POLLOUT, deadline: deadline) else { return false }
            let n = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            rest = rest.dropFirst(n)
        }
        return true
    }
}

/// The one loopback server used by every socket test: binds 127.0.0.1 on an ephemeral port, then (off the main actor)
/// waits for one client with `poll` before `accept`, and hands `serve` a connection whose reads and writes share the
/// same deadline (`seconds` from now, monotonic). A client that never connects, or stops mid-record, ends the server
/// by its deadline; the result is `nil` when nobody connected in time.
func acceptAndServeBounded<T: Sendable>(seconds: Double, _ serve: @escaping @Sendable (BoundedConnection) -> T) throws -> (port: Int, server: Task<T?, Never>) {
    let (listener, port) = try loopbackListener()
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    let server = Task.detached { () -> T? in
        defer { Darwin.close(listener) }
        guard pollUntil(listener, POLLIN, deadline: deadline) else { return nil }
        let conn = Darwin.accept(listener, nil, nil)
        guard conn >= 0 else { return nil }
        defer { Darwin.close(conn) }
        var one: Int32 = 1 // an early client disconnect must never raise SIGPIPE in the test process
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return serve(BoundedConnection(fd: conn, deadline: deadline))
    }
    return (port, server)
}

/// Every non-signature section of a thin 64-bit Mach-O image, keyed `SEGMENT,section`: all segments except
/// `__LINKEDIT` (which holds the code signature), so `__TEXT,__text`, `__TEXT,__cstring`, `__TEXT,__const`, and the data
/// segments all count (zero-fill sections contribute only their size). `codesign` rewrites the signature and the load
/// commands around these bytes, never the bytes themselves, so equal maps prove a signed bundle carries a given build.
func machOSections(_ data: Data) throws -> [String: Data] {
    let bad = AssertionFailure(description: "FAIL: not a thin 64-bit Mach-O image with __TEXT,__text and __TEXT,__cstring")
    let bytes = [UInt8](data)
    func u32(_ o: Int) throws -> Int { guard o >= 0, o + 4 <= bytes.count else { throw bad }; return (0..<4).reduce(0) { $0 | Int(bytes[o + $1]) << (8 * $1) } }
    func u64(_ o: Int) throws -> Int { try u32(o) | (try u32(o + 4)) << 32 }
    func name(_ o: Int) throws -> String { guard o + 16 <= bytes.count else { throw bad }; return String(decoding: bytes[o..<(o + 16)].prefix { $0 != 0 }, as: UTF8.self) }
    guard try u32(0) == 0xfeedfacf else { throw bad } // MH_MAGIC_64 (little-endian)
    var sections: [String: Data] = [:], cmd = 32
    for _ in 0..<(try u32(16)) {
        let size = try u32(cmd + 4), segment = try name(cmd + 8)
        if try u32(cmd) == 0x19, segment != "__LINKEDIT" { // LC_SEGMENT_64
            for k in 0..<(try u32(cmd + 64)) {
                let sect = cmd + 72 + k * 80, length = try u64(sect + 40), offset = try u32(sect + 48)
                let key = "\(segment),\(try name(sect))"
                if [0x1, 0xc, 0x12].contains(try u32(sect + 64) & 0xff) { sections[key] = Data("zerofill:\(length)".utf8); continue } // S_*ZEROFILL
                guard offset + length <= bytes.count else { throw bad }
                sections[key] = Data(bytes[offset..<(offset + length)])
            }
        }
        guard size > 0 else { throw bad }
        cmd += size
    }
    guard sections["__TEXT,__text"] != nil, sections["__TEXT,__cstring"] != nil else { throw bad }
    return sections
}

/// What a 2x `menubar-*-dark` render shows, read from its pixels: icon-button-wide runs on the header's center row
/// (refresh, theme, open, and Quit: 26 pt each), whether the rightmost one (Quit, which ends 14 pt from the edge) holds a
/// glyph that stands out from its own fill, and whether the 8th date pill (364 to 378 pt, clipped by the strip's
/// padding) is drawn over the canvas.
struct MenuChrome: Equatable, CustomStringConvertible {
    let iconButtons: Int, quitGlyph: Bool, eighthPill: Bool
    var description: String { "\(iconButtons) icon buttons, Quit glyph \(quitGlyph), 8th pill \(eighthPill)" }
}

func menuChrome(_ rep: NSBitmapImageRep) -> MenuChrome {
    func lum(_ x: Int, _ y: Int) -> Double {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
        return 255 * (0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
    }
    guard rep.pixelsWide == 784, rep.pixelsHigh == 1120 else { return MenuChrome(iconButtons: 0, quitGlyph: false, eighthPill: false) }
    let canvas = lum(8, 150), headerRow = 46
    var runs: [ClosedRange<Int>] = [], start: Int?
    for x in 400..<782 {
        let drawn = abs(lum(x, headerRow) - canvas) > 4
        if drawn, start == nil { start = x }
        if !drawn, let s = start { runs.append(s...(x - 1)); start = nil }
    }
    if let s = start { runs.append(s...781) }
    let icons = runs.filter { (46...58).contains($0.count) }
    var quitGlyph = false
    if let quit = icons.last, quit.upperBound >= 750 {
        let fill = lum(quit.lowerBound + 3, headerRow)
        quitGlyph = (quit.lowerBound + 14...quit.upperBound - 14).contains { x in (30...62).contains { y in abs(lum(x, y) - fill) > 40 } }
    }
    let pillPixels = (732...752).flatMap { x in stride(from: 190, through: 250, by: 4).map { y in abs(lum(x, y) - canvas) > 4 } }
    return MenuChrome(iconButtons: icons.count, quitGlyph: quitGlyph, eighthPill: pillPixels.filter { $0 }.count * 10 >= pillPixels.count * 8)
}

/// The slot at London wall time `hhmm` on `day` (shared by the loop suites).
func at(_ day: String, _ hhmm: String) -> Slot { Slot(date: day, time: hhmm, start: LondonCalendar.londonWallDate(dateIso: day, hhmm: hhmm)!) }

/// A Canary Wharf timetable row (shared by the loop suites).
func row(_ id: Int, _ day: String, _ hhmm: String, _ title: String = "Row") -> ClassSession {
    ClassSession(id: id, date: day, startTime: hhmm, endTime: "23:59", durationMinutes: 45, title: title, trainer: "", clubName: "Canary Wharf")
}

/// Writes a minimal `Contents/Info.plist` (`CFBundleIdentifier` club.tertia.macos) into the bundle folder `app`, so
/// `publish.py` accepts it as a Tertia bundle it may replace or remove.
func markTertiaBundle(_ app: URL, identifier: String = "club.tertia.macos") throws {
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
}

/// A stored timetable of `clubId` (named from `clubs`, else Canary Wharf) holding `days`, each synced now.
func clubSnapshot(_ days: [String: [ClassSession]], clubId: Int = 39, clubs: [Club] = [canary, woodWharf]) -> TimetableSnapshot {
    let club = clubs.first { $0.id == clubId } ?? canary
    return TimetableSnapshot(clubs: clubs, clubId: clubId, clubName: club.name, clubShortCode: club.shortCode, days: days, syncedAt: Date(), daySyncedAt: days.mapValues { _ in Date() })
}

/// The MCP `book_class` request line for `classId` (raw JSON text, so malformed IDs can be sent too).
func bookLine(_ classId: String) -> String { "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"book_class\",\"arguments\":{\"class_id\":\(classId)}}}" }

/// Sets or clears the immutable flag of `url`, so writes to it fail like a locked file.
func immutable(_ url: URL, _ on: Bool) throws { try FileManager.default.setAttributes([.immutable: on], ofItemAtPath: url.path) }

@main
struct VerifyCoreTests {
    @MainActor
    static func main() async throws {
        Darwin.alarm(95) // one suite deadline, inside test.sh's outer run-watched watchdog
        setvbuf(stdout, nil, _IOLBF, 0) // progress lines survive a crash or an alarm
        let ctx = TestContext()
        defer { ctx.cleanup.forEach { $0() } }
        let suites: [(String, @MainActor (TestContext) async throws -> Void)] = [
            ("parserCalendarIdentity", parserCalendarIdentity),
            ("storeAndAccount", storeAndAccount),
            ("wireContract", wireContract),
            ("cliAndMCP", cliAndMCP),
            ("publicClient", publicClient),
            ("viewModel", viewModel),
            ("widgetHarnessBinary", widgetHarnessBinary),
            ("accountIsolation", accountIsolation),
            ("clubsMenuWidget", clubsMenuWidget),
            ("edgesTransportPackaging", edgesTransportPackaging),
            ("http2WireParity", http2WireParity),
            ("loop4Mutations", loop4Mutations),
            ("loop4StateAndClubs", loop4StateAndClubs),
            ("loop5Transport", loop5Transport),
            ("loop5State", loop5State),
            ("loop6", loop6),
            ("loop7", loop7),
            ("loop8", loop8),
            ("loop9", loop9),
            ("loop10", loop10),
        ]
        for (name, suite) in suites {
            let began = Date()
            try await suite(ctx)
            print("ok: \(name) (\(String(format: "%.1f", Date().timeIntervalSince(began)))s)")
        }
        print("PASS: All Tertia verification suites passed.")
    }
}

/// Scratch folders, test Keychain items, and fixtures shared by the suites (each suite is its own async function so
/// the compiler never has to lower one giant coroutine).
@MainActor final class TestContext {
    let fm = FileManager.default
    var cleanup: [() -> Void] = []

    func scratch(_ name: String) -> URL { let url = tempDir(name); cleanup.append { try? FileManager.default.removeItem(at: url) }; return url }

    /// A fresh throwaway Keychain service (account `verify`), logged for test.sh's cleanup before any item exists and
    /// deleted by this run's cleanup.
    func keychainService(_ name: String) -> String {
        let service = "club.tertia.macos.test.\(name).\(UUID().uuidString)"
        logKeychainService(service)
        cleanup.append { _ = try? KeychainStore(service: service, account: "verify").deleteSession() }
        return service
    }

    func keychain(_ name: String, hooks: KeychainStore.Hooks = .live) -> KeychainStore {
        KeychainStore(service: keychainService(name), account: "verify", hooks: hooks)
    }

    /// Unwritable store (its folder path runs through a regular file), set by `storeAndAccount`.
    var blockedStore: SharedStateStore!

    /// The one offline `render-previews` run (folder and stdout), made by `widgetHarnessBinary` and reused by later suites.
    var renderedPreviews: (dir: URL, stdout: String)?

    fileprivate func freshVM(_ name: String, hooks: KeychainStore.Hooks = .live, mirror: Bool = false, onChange: (@Sendable () -> Void)? = nil,
                 seed: (SharedStateStore, KeychainStore, URL, URL?) throws -> Void = { _, _, _, _ in }) throws -> (vm: ScheduleViewModel, store: SharedStateStore, kc: KeychainStore, mock: MobileMock, dir: URL, mirror: URL?) {
        let dir = self.scratch(name), mdir = mirror ? self.scratch(name + "-mirror") : nil
        for folder in [dir, mdir].compactMap({ $0 }) { try self.fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), kcV = self.keychain(name, hooks: hooks), mock = MobileMock()
        try seed(st, kcV, dir, mdir)
        return (ScheduleViewModel(store: st, keychain: kcV, client: mockPublicClient(store: st), bookingClient: mock.client, onStateChanged: onChange), st, kcV, mock, dir, mdir)
    }
}

@MainActor func parserCalendarIdentity(_ ctx: TestContext) async throws {
    // 1. Parser: PHP [] days, strict malformed days, multiline JSON, club isolation, time and duration validation
    let sampleHTML = """
    <!doctype html><html><body><script>
    let timetable = {"2026-11-20":{"Canary Wharf":[{"id":3064910,"start_time":"10:00","end_time":"10:50","service_title":"Strong &#8211; Bench Press","trainer_name":"Pandora Porter","location_name":"Canary Wharf","duration_hours":0,"duration_minutes":50},{"id":102,"start_time":"07:30","end_time":"08:30","service_title":"Yoga &amp; Breathwork","trainer_name":null,"location_name":"Canary Wharf","duration_hours":1,"duration_minutes":0}]},"2026-11-21":[]};
    let clubs = [{"id":52,"name":"Soho","short_code":"SOHO","hidden":false},{"id":39,"name":"Canary Wharf","short_code":"CANARY","hidden":false},{"id":999,"name":"Internal","short_code":"INT","hidden":true}];
    </script></body></html>
    """
    let parsed = try HTMLTimetableParser.parse(html: sampleHTML)
    try assertEqual(parsed.clubs.map(\.name), ["Canary Wharf", "Soho"], "hidden club excluded and clubs sorted")
    let dayOne = parsed.days["2026-11-20"] ?? []
    try assertEqual(dayOne.map(\.id), [102, 3064910], "classes sorted by numeric start time")
    try assertEqual(dayOne[0].durationMinutes, 60, "duration_hours converted to minutes")
    try assertEqual(dayOne[0].title, "Yoga & Breathwork", "amp decoded")
    try assertEqual(dayOne[1].title, "Strong - Bench Press", "ndash decoded")
    try assertEqual(parsed.days["2026-11-21"]?.count, 0, "PHP empty [] day parsed as empty day")

    func dayPage(_ day: String) -> String { "<script>let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {\"2026-11-20\":\(day)};</script>" }
    let goodClass = "{\"id\":1,\"start_time\":\"10:00\",\"end_time\":\"10:45\",\"service_title\":\"A\",\"duration_minutes\":45"
    for (label, day) in [("non-empty array day", "[1]"), ("primitive day", "\"none\""), ("malformed class", "{\"Canary Wharf\":[{\"id\":\"x\"}]}"),
                         ("invalid start time", "{\"Canary Wharf\":[{\"id\":1,\"start_time\":\"10:00:00:00\",\"end_time\":\"10:45\",\"service_title\":\"A\"}]}"),
                         ("pm suffix time", "{\"Canary Wharf\":[{\"id\":1,\"start_time\":\"10:00pm\",\"end_time\":\"10:45\",\"service_title\":\"A\"}]}"),
                         ("negative duration", "{\"Canary Wharf\":[\(goodClass.replacingOccurrences(of: "\"duration_minutes\":45", with: "\"duration_minutes\":-5"))}]}"),
                         ("overflowing duration", "{\"Canary Wharf\":[{\"id\":1,\"start_time\":\"10:00\",\"end_time\":\"10:45\",\"service_title\":\"A\",\"duration_hours\":\(Int.max)}]}")] {
        try await assertThrows("parser rejects \(label)") { _ = try HTMLTimetableParser.parse(html: dayPage(day)) }
    }
    try assertEqual(try HTMLTimetableParser.parse(html: dayPage("{\"Canary Wharf\":[\(goodClass)}]}")).days["2026-11-20"]?.count, 1, "valid class parses")

    let multilineHTML = """
    <script>
    let clubs = [
      {"id":39,"name":"Canary Wharf","short_code":"CANARY","hidden":false},
      {"id":52,"name":"Soho","short_code":"SOHO","hidden":false}
    ];
    let timetable = {
      "2026-11-20": {
        "Canary Wharf": [
          {"id":1,"start_time":"10:00","end_time":"10:50","service_title":"Abs; Core ] } \\"Burn\\"","location_name":"Canary Wharf","duration_minutes":50},
          {"id":3,"start_time":"11:00","end_time":"11:50","service_title":"Mislabelled","location_name":"Soho","duration_minutes":50}
        ],
        "Soho": [{"id":2,"start_time":"8:30","end_time":"9:15","service_title":"Soho Ride","location_name":"Soho","duration_minutes":45}]
      },
      "2026-11-21": []
    };
    </script>
    """
    let mixed = try HTMLTimetableParser.parse(html: multilineHTML)
    try assertEqual(mixed.days["2026-11-20"]?.map(\.id), [2, 1, 3], "multiline JSON parsed; unpadded 8:30 sorts before 10:00")
    let isolated = try HTMLTimetableParser.parse(html: multilineHTML, clubId: 39)
    try assertEqual(isolated.days["2026-11-20"]?.map(\.id), [1], "clubId keeps only the target club (key and location)")
    try assertEqual(isolated.days["2026-11-20"]?.first?.title, "Abs; Core ] } \"Burn\"", "; ] } and escaped quotes inside titles survive extraction")
    let decoyHTML = """
    <!-- <script>let clubs = [{"id":1,"name":"Comment"}];</script> -->
    <script>
    var note = "let clubs = [{\\"id\\":2,\\"name\\":\\"String\\"}]"; // let timetable = {"x":[]};
    /* let clubs = [{"id":3,"name":"Block"}]; */ var tpl = `let timetable = {}`;
    let clubs = [{"id":39,"name":"Canary Wharf"}];
    let timetable = {"2026-11-20":{"Canary Wharf":[{"id":8,"start_time":"10:00:59","end_time":"11:00","service_title":"let clubs = 1"},{"id":9,"start_time":"10:00:01","end_time":"11:00","service_title":"B"}]}};
    </SCRIPT>
    """
    let decoyParsed = try HTMLTimetableParser.parse(html: decoyHTML)
    try assertEqual(decoyParsed.clubs.map(\.id), [39], "comments, strings, and template literals never count as the clubs declaration")
    try assertEqual(decoyParsed.days["2026-11-20"]?.map(\.id), [9, 8], "sessions sort by exact seconds (10:00:01 before 10:00:59)")

    // 2. LondonCalendar and BookingAuthorization: exact boundaries, seconds, strict stamps, DST gap and repeated hour
    let session = ClassSession(id: 3064910, date: "2026-11-22", startTime: "10:00", endTime: "10:50", durationMinutes: 50, title: "Dynamic Reformer", trainer: "Fallon Stocker", clubName: "Canary Wharf")
    let start = LondonCalendar.startDate(of: session)!
    try assertEqual(LondonCalendar.bookingWindowStatus(for: session, now: start.addingTimeInterval(-48 * 3600 - 60)), .openingSoon("OPENS FRI 10:00"), "openingSoon before 48h mark")
    try assertEqual(LondonCalendar.bookingWindowStatus(for: session, now: start.addingTimeInterval(-48 * 3600)), .open, "open at exactly 48h before start")
    try assertEqual(LondonCalendar.bookingWindowStatus(for: session, now: start.addingTimeInterval(-1)), .open, "open 1s before start")
    try assertEqual(LondonCalendar.bookingWindowStatus(for: session, now: start), .started, "started at exactly start")
    try assertEqual(BookingWindowStatus.started.badgeLabel, "STARTED", "started badge label is STARTED")
    let gapClass = ClassSession(id: 7, date: "2026-03-29", startTime: "01:30", endTime: "02:30", durationMinutes: 60, title: "Gap", trainer: "", clubName: "")
    try assertEqual(LondonCalendar.bookingWindowStatus(for: gapClass).badgeLabel, "UNAVAILABLE", "spring-gap class is invalidTime (UNAVAILABLE)")
    try assertEqual(LondonCalendar.parseIsoDate("2026-02-31"), nil, "rejects rollover Feb 31 date")
    try assertEqual(LondonCalendar.parseIsoDate("2026-1-1"), nil, "rejects non-padded date")
    try assertEqual(LondonCalendar.londonWallDate(dateIso: "2026-11-22", hhmm: "25:00"), nil, "rejects invalid hour")
    for (raw, expected) in [("8:30", 30600), ("08:30", 30600), ("23:59:59", 86399), ("10:00:00:00", nil), ("10:00pm", nil), ("1:5", nil), ("24:00", nil), ("10:60", nil), ("10:00:60", nil), ("", nil), ("+8:30", nil)] as [(String, Int?)] {
        try assertEqual(LondonCalendar.secondsOfDay(raw), expected, "secondsOfDay('\(raw)')")
    }
    try assertEqual(LondonCalendar.londonWallDate(dateIso: "2026-11-22", hhmm: "10:00:59")?.timeIntervalSince(start), 59, "londonWallDate keeps seconds")
    try assertEqual(LondonCalendar.londonWallDate(dateIso: "2026-03-29", hhmm: "01:30"), nil, "spring-forward gap time 01:30 rejected")
    try assertEqual(LondonCalendar.resolveLondonWallTime(dateIso: "2026-10-25", hhmm: "01:30"), .ambiguousRepeatedHour, "repeated autumn 01:30 is ambiguous")
    try assertEqual(LondonCalendar.resolveLondonWallTime(dateIso: "2026-10-25", hhmm: "02:30"), LondonCalendar.parseBookingStart("2026-10-25T02:30:00Z"), "02:30 after the repeated hour is exact GMT")
    try assertEqual(LondonCalendar.dateStrip(days: 0), [], "dateStrip(days: 0) is empty")
    try assertEqual(LondonCalendar.dateStrip(days: -3), [], "dateStrip(negative) is empty")
    let unpadded = ClassSession(id: 5, date: "2099-01-01", startTime: "8:30", endTime: "9:15", durationMinutes: 45, title: "Early", trainer: "", clubName: "")
    try assertEqual(LondonCalendar.filterSessions([unpadded], period: .morning, search: "", selectedDate: "2099-01-01").count, 1, "unpadded 8:30 filters into morning")
    try assertEqual(LondonCalendar.filterSessions([unpadded], period: .evening, search: "", selectedDate: "2099-01-01").count, 0, "unpadded 8:30 is not evening")
    let utc0030 = LondonCalendar.parseBookingStart("2026-10-25T00:30:00Z")
    let stamps: [(String, WallTimeResolution)] = [
        ("2026-11-22T10:00:00Z", .exact(start)), ("2026-11-22T10:00:00.250Z", .exact(start.addingTimeInterval(0.25))),
        ("2026-11-22T11:00:00+01:00", .exact(start)), (" 2026-11-22 10:00 ", .exact(start)), ("2026-11-22T10:00:00", .exact(start)),
        ("2026-10-25T01:30:00", .ambiguousRepeatedHour), ("2026-10-25T01:30:00+01:00", utc0030), ("2026-03-29 01:30", .invalid),
        ("2026-02-31T10:00:00Z", .invalid), ("2026-11-22T10:00:00Zjunk", .invalid), ("2026-11-22T10:00:00+25:00", .invalid),
        ("2026-11-22T10:00.5Z", .invalid), ("2026-11-22T9:00", .invalid), ("tomorrow", .invalid),
    ]
    for (raw, expected) in stamps { try assertEqual(LondonCalendar.parseBookingStart(raw), expected, "parseBookingStart('\(raw)')") }
    try assertTrue(utc0030 != .invalid && utc0030 != LondonCalendar.parseBookingStart("2026-10-25T01:30:00Z"), "zoned stamps inside the repeated hour stay exact and distinct")
    let marks = LondonCalendar.upcomingBoundaryDates(for: [session], now: start.addingTimeInterval(-72 * 3600))
    try assertTrue(marks.first == start.addingTimeInterval(-72 * 3600) && marks == [marks[0]] + marks.dropFirst().sorted()
                   && Set([-60.0, -48, 0].map { start.addingTimeInterval($0 * 3600) }).isSubset(of: Set(marks))
                   && !marks.contains(start.addingTimeInterval(0.25 * 3600)) && !marks.contains(start.addingTimeInterval(-3 * 3600)),
                   "menu redraw boundaries: 60h, 48h, start (no +15m grace or -3h mark)")
    try assertEqual(LondonCalendar.filterSessions([session], period: .all, search: "", selectedDate: "2026-11-22", now: start.addingTimeInterval(-1)).map(\.id), [session.id], "default filter keeps a class 1s before start")
    try assertEqual(LondonCalendar.filterSessions([session], period: .all, search: "", selectedDate: "2026-11-22", now: start), [], "default filter drops a class at its exact start")
    try assertTrue((SampleData.previewSnapshot().days.values.map(\.count)).allSatisfy { $0 >= 6 }, "SampleData has >= 6 classes today and tomorrow")

    let bookedSnap = BookingsSnapshot(ownerKey: "id:1", bookings: [MemberBooking(id: 3064910, title: "", startDate: "2026-11-22T10:00:00Z", clubName: "", trainerName: "", eventAction: "cancel")], syncedAt: Date())
    func cancelRule(_ now: Date, confirmed: Bool = false, stamp: String? = nil, publicSession: ClassSession? = nil, bookings: BookingsSnapshot? = bookedSnap) throws -> BookingAuthorization.CancelDecision {
        let snap = stamp.map { BookingsSnapshot(ownerKey: "id:1", bookings: [MemberBooking(id: 3064910, title: "", startDate: $0, clubName: "", trainerName: "", eventAction: "CANCEL")], syncedAt: Date()) } ?? bookings
        return try BookingAuthorization.authorizeCancellation(classId: 3064910, bookings: snap, confirmedLate: confirmed, now: now) { publicSession.map { ($0, 39, "Canary Wharf") } }
    }
    try assertEqual(try cancelRule(start.addingTimeInterval(-3 * 3600 - 60)), .authorized(lateBooking: false), "3h01m before start is not late")
    try assertEqual(try cancelRule(start.addingTimeInterval(-3 * 3600)), .needsLateConfirmation, "exactly 3h00m before start needs late confirmation (<= 3h)")
    try assertEqual(try cancelRule(start.addingTimeInterval(-3 * 3600 - 1)), .authorized(lateBooking: false), "3h00m01s before start is not late")
    try assertTrue(CompactClassCard.Badge.confirmLateCancel.label == "LATE (<=3H) · CONFIRM?" && ScheduleViewModel.lateConfirmMessage.hasPrefix("3h or less before start"), "late-cancel copy says <= 3h")
    let utcDate = { (raw: String) in ISO8601DateFormatter().date(from: raw)! }
    let bst0130 = utcDate("2026-10-25T00:30:00Z"), gmt0130 = utcDate("2026-10-25T01:30:00Z")
    try assertTrue(LondonCalendar.parseBookingStart("2026-10-25T01:30:00+01:00") == .exact(bst0130) && LondonCalendar.parseBookingStart("2026-10-25T01:30:00+00:00") == .exact(gmt0130)
                   && gmt0130.timeIntervalSince(bst0130) == 3600, "both 01:30 occurrences (BST +01:00, GMT +00:00) parse to fixed instants one hour apart")
    let fromBST = slot(0, from: bst0130), fromGMT = slot(0, from: gmt0130)
    try assertTrue(fromBST.time == "02:30" && fromBST.start.timeIntervalSince(bst0130) == 7200 && fromGMT.time == "02:30" && fromGMT.start.timeIntervalSince(gmt0130) == 3600,
                   "a fixture in the repeated hour moves past it: +7200s from BST 01:30, +3600s from GMT 01:30")
    try assertEqual(try cancelRule(start.addingTimeInterval(-3 * 3600), confirmed: true), .authorized(lateBooking: true), "confirmed late cancel sends lateBooking true")
    try assertEqual(try cancelRule(start.addingTimeInterval(-4 * 3600), confirmed: true), .authorized(lateBooking: false), "--late outside the window sends lateBooking false")
    try assertEqual(try cancelRule(start.addingTimeInterval(-3600), stamp: "", publicSession: session), .needsLateConfirmation, "empty booking stamp falls back to the public row")
    for (label, body) in [("started", { _ = try cancelRule(start) }), ("unknown bookings", { _ = try cancelRule(start.addingTimeInterval(-86400), bookings: nil) }),
                          ("ambiguous stamp", { _ = try cancelRule(start, stamp: "2026-10-25 01:30") }), ("no start time", { _ = try cancelRule(start, stamp: "") }),
                          ("inactive booking", { _ = try cancelRule(start.addingTimeInterval(-86400), bookings: BookingsSnapshot(ownerKey: "id:1", bookings: [], syncedAt: Date())) })] as [(String, () throws -> Void)] {
        try assertTrue(!denial(body).isEmpty, "authorizeCancellation rejects \(label)")
    }
    try assertTrue(denial { _ = try cancelRule(start.addingTimeInterval(-86400), bookings: nil) }.contains("out of sync"), "unknown bookings read as out of sync")
    let emptyBookings = BookingsSnapshot(ownerKey: "id:1", bookings: [], syncedAt: Date())
    func bookRule(_ now: Date, target: ClassSession = session, club: Int = 39, entitled: Set<Int> = [39], bookings: BookingsSnapshot? = emptyBookings) -> String {
        denial { try BookingAuthorization.authorizeBooking(classId: target.id, lookup: entitled.contains(club) ? .unique(session: target, clubId: club) : .missing, bookings: bookings, now: now) }
    }
    try assertEqual(bookRule(start.addingTimeInterval(-48 * 3600)), "", "booking allowed from exactly 48h")
    try assertTrue(bookRule(start.addingTimeInterval(-48 * 3600 - 1)).contains("not open for booking yet"), "booking rejected 1s before 48h")
    try assertTrue(bookRule(start).contains("already started"), "booking rejected at start")
    try assertTrue(bookRule(start.addingTimeInterval(-3600), entitled: [200]).contains("not found"), "booking rejected outside entitled clubs")
    try assertTrue(bookRule(start.addingTimeInterval(-3600), bookings: bookedSnap).contains("already booked"), "booking rejected when already booked")
    try assertTrue(bookRule(start.addingTimeInterval(-3600), bookings: nil).contains("out of sync"), "booking rejected while bookings are unknown")
    let repeatedClass = ClassSession(id: 3064910, date: "2026-10-25", startTime: "01:30", endTime: "02:30", durationMinutes: 60, title: "R", trainer: "", clubName: "")
    try assertTrue(bookRule(LondonCalendar.parseIsoDate("2026-10-24")!, target: repeatedClass).contains("ambiguous clock-change hour"), "booking rejected in the repeated hour")
    try assertTrue(bookRule(LondonCalendar.parseIsoDate("2026-03-28")!, target: ClassSession(id: 3064910, date: "2026-03-29", startTime: "01:30", endTime: "02:30", durationMinutes: 60, title: "G", trainer: "", clubName: "")).contains("Cannot verify valid start time"), "booking rejected in the spring gap")

    // 3. Account identity, opaque owner hash, strict club alignment
    try assertEqual(canaryMember.ownerKey, "id:1", "ownerKey uses member id")
    let emailMember = MemberSession(token: "t", id: 0, name: "", email: "  Mixed@Case.COM ", homeClubId: 0, homeClubName: "", expiresAt: "")
    try assertEqual(emailMember.ownerKey, "email:mixed@case.com", "ownerKey falls back to normalized email")
    try assertEqual(MemberSession(token: "t", id: 0, name: "", email: "  ", homeClubId: 0, homeClubName: "", expiresAt: "").ownerKey, nil, "blank identity has no ownerKey (never 'email:')")
    try assertTrue(emailMember.opaqueOwnerId?.count == 64 && emailMember.opaqueOwnerId?.contains("mixed") == false && emailMember.opaqueOwnerId != canaryMember.opaqueOwnerId, "opaqueOwnerId is a 256-bit hex hash, never the raw email")
    let chelseaPrefs = TertiaPreferences(clubId: 220, clubName: "Chelsea", clubShortCode: "CHE")
    guard case .realigned(let realigned) = chelseaPrefs.alignment(for: canaryMember, catalog: Club.defaultClubs) else { throw AssertionFailure(description: "FAIL: Chelsea should realign") }
    try assertEqual(realigned.clubId, 39, "alignment switches disallowed Chelsea to home club 39")
    try assertEqual(realigned.alignment(for: canaryMember, catalog: Club.defaultClubs), .unchanged, "alignment is unchanged when already entitled")
    let venueOnly = MemberSession(token: "t", id: 3, name: "", email: "", homeClubId: 145, homeClubName: "Membership Only", expiresAt: "", clubs: [Club(id: 145, name: "Membership Only", shortCode: "")])
    try assertTrue(venueOnly.entitledClubs(from: Club.defaultClubs).isEmpty && chelseaPrefs.alignment(for: venueOnly, catalog: Club.defaultClubs) == .noneEntitled, "membership-only venue yields no timetable clubs (noneEntitled)")
    try assertEqual(MemberSession(token: "t", id: 2, name: "", email: "", homeClubId: 0, homeClubName: "", expiresAt: "").entitledClubs(from: Club.defaultClubs), [], "no club entitlements yields no clubs (never all 17)")
    try assertEqual(MemberSession(token: "t", id: 2, name: "", email: "", homeClubId: 52, homeClubName: "Soho", expiresAt: "").entitledClubs(from: Club.defaultClubs).map(\.name), ["Soho"], "single-club member scoped to home club")
    let legacySession = try JSONDecoder().decode(MemberSession.self, from: Data("{\"token\":\"t\",\"id\":5,\"name\":\"N\",\"email\":\"e@x.com\",\"homeClubId\":39,\"homeClubName\":\"Canary Wharf\",\"expiresAt\":\"\"}".utf8))
    try assertTrue(legacySession.clubs.isEmpty && legacySession.ownerKey == "id:5", "legacy Keychain session without clubs still decodes")

}

@MainActor func storeAndAccount(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 4. SharedStateStore: account-bound bookings, opaque widget mirror, strict writes, cross-process preferences
    let storeDir = ctx.scratch("store"), mirrorDir = ctx.scratch("mirror")
    let store = SharedStateStore(primaryDirectory: storeDir, mirrorDirectory: mirrorDir)
    let prefs = TertiaPreferences(clubId: 201, clubName: "Clapham Junction", clubShortCode: "CLJ", period: .evening, searchQuery: "Reformer")
    try store.seedPreferences(prefs)
    try assertEqual(store.loadPreferences(), prefs, "preferences round-trip")
    try store.seedSnapshot(SampleData.previewSnapshot())
    try assertEqual(store.loadSnapshot(clubId: 39)?.clubName, "Canary Wharf", "snapshot round-trip")
    let legacySnapshot = Data("{\"clubs\":[],\"clubId\":5,\"clubName\":\"X\",\"clubShortCode\":\"X\",\"days\":{},\"syncedAt\":\"2026-01-01T00:00:00Z\"}".utf8)
    try legacySnapshot.write(to: storeDir.appendingPathComponent("snapshot-5.json"))
    try assertEqual(store.loadSnapshot(clubId: 5)?.daySyncedAt, [:], "legacy snapshot decodes with empty daySyncedAt")
    let malformedDir = ctx.scratch("malformed")
    try fm.createDirectory(at: malformedDir, withIntermediateDirectories: true)
    try "{broken".write(to: malformedDir.appendingPathComponent("preferences.json"), atomically: true, encoding: .utf8)
    let malformedStore = SharedStateStore(primaryDirectory: malformedDir)
    try await assertThrows("readPreferences throws for malformed preferences.json") { _ = try malformedStore.readPreferences() }
    try await assertThrows("updatePreferences refuses to overwrite malformed preferences.json") { try malformedStore.updatePreferences { $0.period = .morning } }
    try assertEqual(try String(contentsOf: malformedDir.appendingPathComponent("preferences.json"), encoding: .utf8), "{broken", "malformed preferences.json left untouched")
    try assertEqual(try SharedStateStore(primaryDirectory: ctx.scratch("fresh")).readPreferences(), TertiaPreferences(), "missing preferences.json reads as defaults")

    let canaryOwner = canaryMember.opaqueOwnerId!
    try "{\"bookings\":[],\"syncedAt\":\"2026-01-01T00:00:00Z\",\"title\":\"legacy full record\"}".write(to: mirrorDir.appendingPathComponent("bookings.json"), atomically: true, encoding: .utf8)
    let storeKC = ctx.keychain("store")
    try loginSeed(store, canaryMember, storeKC, bookingsA.bookings)
    try assertEqual(store.loadBookings(for: canaryMember)?.bookedIds, Set([3064910]), "bookedIds matches cancel case-insensitively")
    let otherMember = MemberSession(token: "t2", id: 2, name: "B", email: "b@b.com", homeClubId: 39, homeClubName: "", expiresAt: "")
    try assertEqual(store.loadBookings(for: otherMember), nil, "another account never sees cached bookings")
    let mirrorText = try String(contentsOf: mirrorDir.appendingPathComponent("bookings.json"), encoding: .utf8)
    let mirrorJSON = try JSONSerialization.jsonObject(with: Data(mirrorText.utf8)) as? [String: Any] ?? [:]
    try assertEqual(Set(mirrorJSON.keys), ["bookedIds", "ownerId", "rowTokens"], "widget mirror overwritten with booked IDs, opaque owner, and opaque row tokens only")
    try assertEqual(mirrorJSON["rowTokens"] as? [String], [SharedStateStore.widgetRowToken(classId: 3064910, clubName: "Canary Wharf", dateIso: "2026-11-22")],
                    "the row token is the one-way digest of the booked row's ID, club, and London date (no readable club or date)")
    try assertEqual(mirrorJSON["bookedIds"] as? [Int], [3064910], "widget mirror holds only active IDs (no titles, dates, trainers, waitlist)")
    try assertTrue(mirrorJSON["ownerId"] as? String == canaryOwner && !mirrorText.contains("id:1"), "widget mirror owner is the opaque hash")
    try assertEqual(try String(contentsOf: mirrorDir.appendingPathComponent("account.json"), encoding: .utf8), "{\"bookingsValid\":true,\"ownerId\":\"\(canaryOwner)\"}", "account.json mirrored with the opaque owner and validity only")
    let widgetStore = SharedStateStore(primaryDirectory: mirrorDir)
    try assertEqual(widgetStore.loadBookedIds(), Set([3064910]), "widget reads compact mirror for the marked account")
    try assertEqual(store.loadBookedIds(), Set([3064910]), "app reads full bookings for the marked account")
    try assertEqual(store.loadBookedIds(expectedOwnerId: otherMember.opaqueOwnerId), [], "loadBookedIds filters by expected owner")
    try "{\"ownerId\":\"\(otherMember.opaqueOwnerId!)\"}".write(to: mirrorDir.appendingPathComponent("account.json"), atomically: true, encoding: .utf8)
    try assertEqual(widgetStore.loadBookedIds(), [], "badges hidden when account.json names another account")
    try fm.removeItem(at: mirrorDir.appendingPathComponent("account.json"))
    try assertEqual(widgetStore.loadBookedIds(), [], "badges hidden when account.json is missing")
    try "{\"bookings\":[],\"syncedAt\":\"2026-01-01T00:00:00Z\"}".write(to: storeDir.appendingPathComponent("bookings.json"), atomically: true, encoding: .utf8)
    try assertEqual(store.loadBookings(for: canaryMember), nil, "legacy ownerless bookings.json is ignored")
    let ownerless = MemberSession(token: "t", id: 0, name: "", email: " ", homeClubId: 0, homeClubName: "", expiresAt: "")
    try await assertThrows("bookings without an owner are never stored") { _ = try store.commitSyncedBookings(bookingsA.bookings, for: ownerless, startedAtRevision: 0, syncSeq: 0, keychain: storeKC) }
    try loginSeed(store, canaryMember, storeKC, bookingsA.bookings)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mirrorDir.path)
    let lockedClear = try store.clearSession(keychain: storeKC)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mirrorDir.path)
    try assertTrue(lockedClear.didClear && lockedClear.cacheError != nil, "an existing mirror file that cannot be removed is reported")
    try loginSeed(store, canaryMember, storeKC, bookingsA.bookings)
    try assertTrue(try store.clearSession(keychain: storeKC).cacheError == nil, "sign-out cleanup succeeds once the mirror is writable")
    try assertTrue(!fm.fileExists(atPath: storeDir.appendingPathComponent("bookings.json").path) && !fm.fileExists(atPath: mirrorDir.appendingPathComponent("bookings.json").path), "sign-out removes primary and mirror bookings files")

    let blocker = ctx.scratch("blocker")
    try Data().write(to: blocker)
    let blockedStore = SharedStateStore(primaryDirectory: blocker.appendingPathComponent("sub"))
    ctx.blockedStore = blockedStore
    try await assertThrows("updatePreferences throws when the primary directory is unwritable") { try blockedStore.updatePreferences { $0 = prefs } }
    try await assertThrows("commitLogin throws when the primary directory is unwritable") { _ = try blockedStore.commitLogin(canaryMember, keychain: storeKC) }
    try await assertThrows("explicit mirror failures throw") {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("ok"), mirrorDirectory: blocker.appendingPathComponent("m"))
        _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [todayIso: []], fetchedRange: [todayIso],
                                        requestSeq: try st.reserveSnapshotSequence(), syncedAt: Date())
    }

    let sharedDir = ctx.scratch("prefs-lock")
    let writers = (SharedStateStore(primaryDirectory: sharedDir), SharedStateStore(primaryDirectory: sharedDir))
    try writers.0.seedPreferences(TertiaPreferences(searchQuery: ""))
    DispatchQueue.concurrentPerform(iterations: 200) { i in
        _ = try? (i % 2 == 0 ? writers.0 : writers.1).updatePreferences { $0.searchQuery += "x" }
    }
    try assertEqual(writers.0.loadPreferences().searchQuery.count, 200, "updatePreferences serializes read-modify-write across store instances (flock)")
    try writers.1.updatePreferences { $0.period = .morning }
    try writers.0.updatePreferences { $0.clubId = 52 }
    try assertEqual([writers.1.loadPreferences().period == .morning, writers.1.loadPreferences().clubId == 52], [true, true], "concurrent edits to different fields both survive")

    // 5. KeychainStore without UI, and account commits under one cross-process lock
    let kc = ctx.keychain("core")
    try assertEqual(try kc.readSession(), nil, "readSession returns nil only for a missing item")
    try seedForeignKeychainItem(service: kc.service, account: kc.account)
    try await assertThrows("readSession throws for a foreign-ACL or corrupt item instead of reporting signed out") { _ = try kc.readSession() }
    let sessionObj = MemberSession(token: "tok_secret_123", id: 42, name: "Alex Morgan", email: "alex@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "2026-12-01T00:00:00Z", clubs: [canary])
    try kc.saveSession(sessionObj)
    try assertEqual(try kc.readSession(), sessionObj, "saveSession replaced the stale foreign (ACL-rejected) item")
    try assertEqual(sessionObj.firstName, "Alex", "firstName extracted")
    let errSecNotAvailable: Int32 = -25291, errSecInteractionNotAllowed: Int32 = -25308
    let transient = KeychainStore(service: kc.service, account: kc.account, hooks: .init(statusOverride: errSecNotAvailable))
    try assertEqual(denial { try transient.saveSession(canaryMember) }, KeychainError.osStatus(errSecNotAvailable).localizedDescription, "transient Keychain error throws")
    try assertEqual(try kc.readSession(), sessionObj, "transient error never deletes the existing item")
    for (label, hooks) in [("set", KeychainStore.Hooks(setInteractionAllowed: { _ in -50 })), ("get", KeychainStore.Hooks(getInteractionAllowed: { (-50, true) }))] {
        try assertEqual(denial { _ = try KeychainStore(service: kc.service, account: kc.account, hooks: hooks).readSession() }, KeychainError.osStatus(-50).localizedDescription, "interaction \(label) failure throws before any SecItem call")
    }
    let hungTool = ctx.scratch("hung-security")
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: hungTool, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hungTool.path)
    let hungStarted = Date()
    try await assertThrows("a hung security helper fails") { try KeychainStore(service: kc.service, account: kc.account, hooks: .init(statusOverride: errSecInteractionNotAllowed, securityToolPath: hungTool.path)).deleteSession() }
    try assertTrue(Date().timeIntervalSince(hungStarted) < 5.5, "security helper fallback is bounded (3s, then SIGTERM/SIGKILL)")

    let acctDir = ctx.scratch("account"), acctMirror = ctx.scratch("account-mirror")
    let acct = SharedStateStore(primaryDirectory: acctDir, mirrorDirectory: acctMirror)
    try assertEqual(try acct.commitLogin(sessionObj, keychain: kc).cacheError == nil, true, "commitLogin saves the session")
    let rev0 = try acct.beginBookingsSync(for: sessionObj, keychain: kc), rev1 = try acct.beginBookingsSync(for: sessionObj, keychain: kc)
    let committed = try acct.commitSyncedBookings(bookingsA.bookings, for: sessionObj, started: rev1, syncedAt: Date(), keychain: kc).snapshot
    try assertEqual(acct.loadBookings(for: sessionObj), committed, "commitSyncedBookings stores the current account's bookings")
    let stale = try acct.commitSyncedBookings([], for: sessionObj, started: rev0, syncedAt: Date(), keychain: kc).snapshot
    try assertTrue(stale == committed && acct.loadBookings(for: sessionObj)?.bookedIds == [3064910], "a refresh that overlapped a newer commit returns the newer snapshot (memory and disk)")
    try assertEqual(denial { _ = try acct.commitSyncedBookings([], for: memberB, started: rev0, keychain: kc) }, BookingClientError.sessionSuperseded.localizedDescription, "a superseded session's bookings are never committed")
    try assertEqual(denial { _ = try acct.commitLogin(memberB, keychain: transient) }, KeychainError.osStatus(errSecNotAvailable).localizedDescription, "commitLogin fails when the Keychain save fails")
    try assertTrue(try kc.readSession() == sessionObj && acct.loadBookings(for: sessionObj) != nil && acct.loadBookedIds() == [3064910], "a failed login save leaves the previous credential, marker, and cache intact")
    try assertEqual(try acct.commitLogin(memberB, keychain: kc).cacheError == nil, true, "commitLogin switches account")
    try assertTrue(try kc.readSession() == memberB && acct.loadBookings(for: sessionObj) == nil && !fm.fileExists(atPath: acctMirror.appendingPathComponent("bookings.json").path), "login drops the previous account's bookings everywhere")
    try assertEqual(try String(contentsOf: acctMirror.appendingPathComponent("account.json"), encoding: .utf8), "{\"bookingsValid\":false,\"ownerId\":\"\(memberB.opaqueOwnerId!)\"}", "login re-marks the mirror account (bookings unknown until synced)")
    _ = try acct.commitSyncedBookings(bookingsA.bookings, for: memberB, started: try acct.beginBookingsSync(for: memberB, keychain: kc), keychain: kc)
    try assertEqual(acct.invalidateBookingsForFailedFollowUp(for: sessionObj, keychain: kc), .superseded, "a stale follow-up never clears another account's bookings")
    try assertEqual(expiryKind(acct.expireSession(for: sessionObj, keychain: kc)), "superseded", "expiring a replaced token leaves the new session alone")
    try assertTrue(try kc.readSession() == memberB && acct.loadBookings(for: memberB) != nil, "replacement session and cache untouched")
    try assertEqual(expiryKind(acct.expireSession(for: memberB, keychain: kc)), "cleared", "expiring the current token clears it")
    let primaryMarker = try JSONSerialization.jsonObject(with: Data(contentsOf: acctDir.appendingPathComponent("account.json"))) as? [String: Any] ?? [:]
    try assertTrue(try kc.readSession() == nil && primaryMarker["ownerId"] == nil && (primaryMarker["revision"] as? Int ?? 0) > 0 && !fm.fileExists(atPath: acctMirror.appendingPathComponent("account.json").path),
                   "expiry removes the credential and the mirror marker; the primary marker keeps only its revision")
    try loginSeed(store, canaryMember, kc, bookingsA.bookings)
    let cleared = try store.clearSession(keychain: kc)
    try assertTrue(cleared.didClear && cleared.cacheError == nil, "clearSession signs out cleanly")
    try assertTrue(try kc.readSession() == nil && store.loadBookings(for: canaryMember) == nil, "clearSession removes Keychain item and cached bookings")

}

@MainActor func wireContract(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 6. MobileBookingClient wire contract, guarded sync, partial mutation outcome
    let wire = MobileMock()
    wire.bookings.value["tok_A"] = classesJSON([(3064910, "2026-11-22T10:00:00Z")])
    let logged = try await wire.client.login(email: "a@example.com", password: "p@ss\"w\\ord")
    try assertEqual(logged.token, "tok_A", "login decoded token")
    let loginReq = wire.requests.value[0]
    try assertEqual(loginReq.url, "https://api.thirdspace-london.app/api/v2/member/auth/login?api-version=2.0", "login URL")
    try assertEqual(loginReq.headers.map(\.name), ["User-Agent", "Accept-Encoding", "x-app-platform", "x-app-version", "Content-Type"], "login header order, no token")
    try assertEqual(loginReq.headers.map(\.value), ["okhttp/4.12.0", "gzip", "android", "6.7.4", "application/json"], "login header values match Android 6.7.4")
    try assertEqual(loginReq.body, "{\"email\":\"a@example.com\",\"password\":\"p@ss\\\"w\\\\ord\"}", "login body exact key order & escaping")
    let noHome = try await MobileBookingClient { _ in (200, Data("{\"token\":\"x\",\"email\":\"  \"}".utf8)) }.login(email: " Z@z.com ", password: "p")
    try assertEqual(noHome.homeClubId, 0, "missing homeClubId maps to 0, not Canary Wharf")
    try assertEqual(noHome.entitledClubs(from: Club.defaultClubs), [], "session without entitlements gets no clubs")
    try assertTrue(noHome.email == "Z@z.com" && noHome.ownerKey == "email:z@z.com", "blank returned email falls back to the trimmed login email")

    let guardDir = ctx.scratch("guard"), guardKC = ctx.keychain("guard")
    let guardStore = SharedStateStore(primaryDirectory: guardDir)
    try await assertThrows("sync for a session the Keychain no longer holds is superseded") { _ = try await wire.client.syncBookings(for: logged, store: guardStore, keychain: guardKC) }
    try assertEqual(guardStore.loadBookings(for: logged), nil, "a superseded sync saves nothing")
    try guardKC.saveSession(logged)
    let outcome = try await wire.client.mutateAndSync(classId: 3064910, isCancel: false, session: logged, store: guardStore, keychain: guardKC) { _, _, _ in false }
    guard case .synced(let syncedSnap, _) = outcome else { throw AssertionFailure(description: "FAIL: mutateAndSync should sync") }
    try assertEqual(syncedSnap.bookedIds, Set([3064910]), "mutateAndSync books then syncs")
    try assertEqual(guardStore.loadBookings(for: logged)?.ownerKey, logged.ownerKey, "synced bookings are owned by the session")
    let reqs = wire.requests.value
    try assertTrue(reqs[reqs.count - 2].body == "{\"classId\":3064910}" && reqs[reqs.count - 2].method == "POST", "book_class exact JSON over POST")
    try assertEqual(reqs.last?.url, "https://api.thirdspace-london.app/api/v2/member/classes?api-version=2.0&Limits.Count=100&Range=future&Cancelled=false&ExcludeWaitingOnly=false", "fetchBookings exact query")
    wire.classesStatus.value["tok_A"] = 503
    let partial = try await wire.client.mutateAndSync(classId: 3064910, isCancel: true, session: logged, store: guardStore, keychain: guardKC) { _, _, _ in true }
    try assertTrue(wire.requests.value[wire.count - 2].body == "{\"classId\":3064910,\"lateBooking\":true}" && wire.requests.value[wire.count - 2].method == "PUT", "cancel_booking exact JSON key order over PUT")
    guard case .acceptedRefreshFailed(_, followUp: .cacheCleanup(.cleared)) = partial else { throw AssertionFailure(description: "FAIL: accepted mutation + failed sync should report acceptedRefreshFailed") }
    try assertEqual(guardStore.loadBookings(for: logged), nil, "failed post-mutation sync clears stale bookings.json")
    wire.classesStatus.value["tok_A"] = 401
    guard case .acceptedRefreshFailed(let expiredError, followUp: .sessionExpired(let expiry)) = try await wire.client.mutateAndSync(classId: 3064910, isCancel: false, session: logged, store: guardStore, keychain: guardKC, authorize: { _, _, _ in false }),
          BookingClientError.isUnauthorized(expiredError), expiryKind(expiry) == "cleared" else { throw AssertionFailure(description: "FAIL: 401 follow-up should be reported as a cleared session") }
    try assertEqual(try guardKC.readSession(), nil, "401 on the follow-up sync expires the current session")
    for (status, body, unauthorized) in [(401, "{\"message\":\"nope\"}", true), (403, "{\"message\":\"Token expired\"}", true), (403, "{\"message\":\"Membership does not include this class\"}", false),
                                            (403, "{\"message\":\"Booking token quota reached\"}", false), (403, "{\"message\":\"This is not an invalid token\"}", false)] {
        let denied = MobileBookingClient { _ in (status, Data(body.utf8)) }
        var thrown: Error?
        do { try await denied.bookClass(classId: 1, token: "t") } catch { thrown = error }
        try assertEqual(BookingClientError.isUnauthorized(thrown), unauthorized, "HTTP \(status) \(body) unauthorized=\(unauthorized)")
    }
    try assertEqual(try MobileBookingClient.escapeCurlConfig("a\r\nb\t\"\\"), "a\\r\\nb\\t\\\"\\\\", "curl escaping is scalar by scalar (CRLF becomes \\r\\n)")
    try await assertThrows("other control characters are rejected") { _ = try MobileBookingClient.escapeCurlConfig("a\u{01}b") }
    for bad in [MobileRequest(method: "GET\r\nX: y", url: "https://x", headers: []), MobileRequest(method: "GET", url: "https://x\n", headers: []),
                MobileRequest(method: "GET", url: "https://x", headers: [HTTPHeader(name: "A:B", value: "v")]), MobileRequest(method: "GET", url: "https://x", headers: [HTTPHeader(name: "A", value: "v\r\nInjected: 1")])] {
        try await assertThrows("curl config rejects line injection in \(bad.method.prefix(3))") { _ = try MobileBookingClient.buildCurlConfig(bad) }
    }
    setenv("SystemRoot", "D:\\Win", 1); setenv("WINDIR", "D:\\Win", 1)
    try assertEqual(MobileBookingClient.resolveCurlExecutablePath(), "/usr/bin/curl", "curl path is pinned on macOS regardless of SystemRoot/WINDIR")
    unsetenv("SystemRoot"); unsetenv("WINDIR")
    try assertTrue(MobileBookingClient.CommandHooks.live.executablePath == "/usr/bin/curl" && MobileBookingClient.CommandHooks.live.arguments == ["--disable", "--config", "-"],
                   "live curl command is fixed: --disable first, config (and password) only on stdin")

    // 7. Real /usr/bin/curl transport: --disable, stdin config, fragmented socket I/O, no secrets in ps
    let capture = Locked("")
    let (port, serverTask) = try acceptAndServeBounded(seconds: 4) { conn in
        var received = [UInt8]()
        func complete() -> Bool {
            guard let end = (0..<max(0, received.count - 3)).first(where: { received[$0..<$0 + 4].elementsEqual("\r\n\r\n".utf8) }) else { return false }
            let head = String(decoding: received[..<end], as: UTF8.self).lowercased()
            let length = head.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            return received.count - end - 4 >= length
        }
        while !complete() { guard let chunk = conn.read(64) else { break }; received += chunk } // tiny reads force fragmentation
        capture.value = String(decoding: received, as: UTF8.self)
        let body = "{\"token\":\"loopback_tok\",\"id\":9,\"name\":\"Alex Morgan\"}"
        for (i, chunk) in ["HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n", "Content-Length: \(body.utf8.count)\r\n\r\n\(body.prefix(10))", String(body.dropFirst(10))].enumerated() {
            if i > 0 { usleep(30_000) }
            guard conn.write(Array(chunk.utf8)) else { return }
        }
    }
    let curlHome = ctx.scratch("curlhome")
    try fm.createDirectory(at: curlHome, withIntermediateDirectories: true)
    try "header = \"X-Curlrc-Leak: yes\"\n".write(to: curlHome.appendingPathComponent(".curlrc"), atomically: true, encoding: .utf8)
    let savedHome = ProcessInfo.processInfo.environment["HOME"]
    setenv("HOME", curlHome.path, 1); setenv("CURL_HOME", curlHome.path, 1)
    let loopSession = try await MobileBookingClient(baseURL: "http://127.0.0.1:\(port)").login(email: "a@b.com", password: "p@ss\"w\\ord")
    if let savedHome { setenv("HOME", savedHome, 1) }; unsetenv("CURL_HOME")
    await serverTask.value
    let rawWire = capture.value
    try assertEqual(loopSession.token, "loopback_tok", "curl decoded fragmented response")
    let wireHead = rawWire.components(separatedBy: "\r\n\r\n").first?.components(separatedBy: "\r\n") ?? []
    let loopBody = "{\"email\":\"a@b.com\",\"password\":\"p@ss\\\"w\\\\ord\"}"
    try assertEqual(wireHead.first, "POST /api/v2/member/auth/login?api-version=2.0 HTTP/1.1", "HTTP/1.1 request line")
    try assertEqual(Array(wireHead.dropFirst()), ["Host: 127.0.0.1:\(port)", "User-Agent: okhttp/4.12.0", "Accept-Encoding: gzip", "x-app-platform: android", "x-app-version: 6.7.4",
                                                  "Content-Type: application/json", "Content-Length: \(loopBody.utf8.count)"], "HTTP/1.1 headers are exactly the Android set, in order, with no Accept")
    try assertTrue(!rawWire.contains("Accept: */*"), "default curl Accept header suppressed")
    try assertTrue(!rawWire.contains("X-Curlrc-Leak"), "--disable ignores a ~/.curlrc in HOME/CURL_HOME")
    try assertTrue(rawWire.contains("{\"email\":\"a@b.com\",\"password\":\"p@ss\\\"w\\\\ord\"}"), "password survived curl config escaping")
    let expectedHTTPS = """
    url = "https://api.thirdspace-london.app/api/v2/member/auth/login?api-version=2.0"
    request = "POST"
    compressed
    max-time = "15"
    silent
    show-error
    write-out = "\\n%{http_code}"
    header = "Accept:"
    http2
    tlsv1.2
    tls-max = "1.3"
    ciphers = "TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-SHA:ECDHE-RSA-AES256-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA:AES256-SHA"
    curves = "X25519:P-256:P-384"
    header = "User-Agent: okhttp/4.12.0"
    header = "Accept-Encoding: gzip"
    header = "x-app-platform: android"
    header = "x-app-version: 6.7.4"
    header = "Content-Type: application/json"
    data-raw = "{\\"email\\":\\"a@example.com\\",\\"password\\":\\"p@ss\\\\\\"w\\\\\\\\ord\\"}"

    """
    try assertEqual(try MobileBookingClient.buildCurlConfig(loginReq), expectedHTTPS, "https curl config matches the independent Android 6.7.4 literal")

}

@MainActor func cliAndMCP(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 8. CLI: parsing, account scoping, local 48h/3h/started validation, partial outcomes, cross-account login
    let parsedEq = try TertiaCLI.parseOptions(["--club=39", "--json", "pos"], valueFlags: ["--club"], boolFlags: ["--json"])
    try assertEqual(parsedEq.values["--club"], "39", "parseOptions supports --flag=val")
    try assertEqual(parsedEq.positionals, ["pos"], "parseOptions captures positionals")
    try await assertThrows("parseOptions rejects unknown flags") { _ = try TertiaCLI.parseOptions(["--bogus"]) }
    try await assertThrows("parseOptions rejects next long flag as missing value") { _ = try TertiaCLI.parseOptions(["--email", "--password-stdin"], valueFlags: ["--email"], boolFlags: ["--password-stdin"]) }
    try assertTrue(TertiaCLI.shouldHandle(firstArg: "clubs") && !TertiaCLI.shouldHandle(firstArg: "--window") && !TertiaCLI.shouldHandle(firstArg: nil), "shouldHandle routes CLI vs GUI")

    MockHTTPBox.shared.set(39, body: page39)
    MockHTTPBox.shared.set(200, body: timetableHTML([Fx(id: 601, slot: openSlot, title: "Wood Wharf Ride", club: "Wood Wharf")]))
    MockHTTPBox.shared.set(220, body: timetableHTML([]))

    let cliDir = ctx.scratch("cli")
    let cliStore = SharedStateStore(primaryDirectory: cliDir)
    let cliPublic = mockPublicClient(store: cliStore)
    let cliKC = ctx.keychain("cli")
    let cli = MobileMock()
    let notified = Locked(0)
    func runCLI(_ args: [String]) async throws -> (code: Int32, out: String) {
        try await captureOutput { await TertiaCLI.run(args: args, store: cliStore, keychain: cliKC, client: cliPublic, bookingClient: cli.client) { notified.mutate { $0 += 1 } } }
    }
    func mcp(_ line: String) async -> String? { await MCPServer.handleLine(line, store: cliStore, keychain: cliKC, client: cliPublic, bookingClient: cli.client) }
    func call(_ tool: String, _ args: String = "{}") async -> String? { await mcp("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":\(args)}}") }
    try assertEqual(try await runCLI([]).code, 0, "empty args prints usage")
    try assertEqual(try await runCLI(["unknowncmd"]).code, 1, "unknown cmd returns 1")
    try assertEqual(try await runCLI(["clubs", "extra"]).code, 1, "clubs rejects positional")
    try assertEqual(try await runCLI(["timetable", "--date", "2026-02-31"]).code, 1, "CLI rejects invalid calendar date")
    try assertEqual(try await runCLI(["timetable", "--club", "0"]).code, 1, "CLI rejects club 0")

    // Cross-account login: A's cached bookings must not survive B's login, even when B's sync fails.
    try loginSeed(cliStore, memberA, cliKC, bookingsA.bookings)
    func notifications(_ run: () async throws -> (code: Int32, out: String)) async throws -> (code: Int32, out: String, notified: Int) {
        let before = notified.value
        let res = try await run()
        return (res.code, res.out, notified.value - before)
    }
    cli.classesStatus.value["tok_B"] = 503
    setenv("TERTIA_PASSWORD", "secret", 1)
    var counted = try await notifications { try await runCLI(["login", "--email", "b@example.com"]) }
    try assertEqual([counted.code, Int32(counted.notified)], [1, 1], "login with failed sync exits 1 but still notifies once for the new credential")
    try assertTrue(!fm.fileExists(atPath: cliDir.appendingPathComponent("bookings.json").path), "login clears the previous account's bookings before syncing")
    try assertEqual(try cliKC.readSession()?.token, "tok_B", "login saved the new session")
    try assertEqual(try await runCLI(["bookings"]).code, 1, "bookings without cache exits 1")
    cli.classesStatus.value["tok_B"] = 401
    counted = try await notifications { try await runCLI(["login", "--email", "b@example.com"]) }
    try assertTrue(counted.code == 1 && !counted.out.contains("Signed in") && counted.notified == 2, "login whose new token is rejected (401) never claims success")
    try assertEqual(try cliKC.readSession(), nil, "a rejected new token is cleared")
    cli.classesStatus.value["tok_B"] = 200
    cli.bookings.value["tok_A"] = classesJSON([(502, isoUTC(lateSlot.start)), (504, isoUTC(pastSlot.start))])
    counted = try await notifications { try await runCLI(["login", "--email", "a@example.com"]) }
    try assertEqual([counted.code, Int32(counted.notified)], [0, 2], "login as A succeeds and notifies for credential and bookings")
    unsetenv("TERTIA_PASSWORD")
    try assertEqual(cliStore.loadBookings(for: memberA)?.bookedIds, Set([502, 504]), "login synced A's bookings")

    /// `actions` counts book and cancel requests; `total` counts every private request (bookings syncs included), so a
    /// refusal is checked against `total`.
    func actionCount(_ run: () async throws -> (code: Int32, out: String)) async throws -> (code: Int32, out: String, actions: Int, total: Int) {
        let before = cli.count
        let res = try await run()
        return (res.code, res.out, cli.actions(after: before).count, cli.count - before)
    }
    // One unexpected bookings sync is a private request: `total` catches it where the book/cancel count would not.
    var res = try await actionCount { try await runCLI(["bookings", "--refresh"]) }
    try assertTrue(res.total == 1 && res.actions == 0, "a lone /member/classes request counts as a private request")
    res = try await actionCount { try await runCLI(["book", "999999"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "book rejects a class missing from the public timetable without API calls")
    res = try await actionCount { try await runCLI(["book", "504"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "book rejects an already-booked class locally")
    res = try await actionCount {
        let dawnNow = dawnSlot.start.addingTimeInterval(3600)
        return (0, await denialAsync { _ = try await TertiaCLI.performMutation(classId: 505, isCancel: false, late: false, store: cliStore, keychain: cliKC, client: cliPublic, bookingClient: cli.client, nowProvider: { dawnNow }) })
    }
    try assertTrue(res.out.contains("Class 505 has already started.") && res.total == 0, "book rejects a started (00:01) class locally (fixed clock)")
    res = try await actionCount { try await runCLI(["book", "503"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "book rejects a class outside the 48h window locally")
    counted = try await notifications { try await runCLI(["book", "501"]) }
    try assertEqual([counted.code, Int32(counted.notified)], [0, 1], "book succeeds for a 48H OPEN class and notifies once")
    try assertTrue(counted.out.contains("Booked class 501. Active bookings: 2."), "book reports refreshed bookings")
    res = try await actionCount { try await runCLI(["cancel", "502"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "cancel inside 3h without --late is rejected locally")
    res = try await actionCount { try await runCLI(["cancel", "504", "--late"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "cancel of a started class is rejected locally")
    res = try await actionCount { try await runCLI(["cancel", "777"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "cancel of a class missing from active bookings is rejected locally")
    res = try await actionCount { try await runCLI(["cancel", "502", "--late"]) }
    try assertEqual([res.code, Int32(res.actions)], [0, 1], "cancel --late inside 3h succeeds")
    try assertEqual(cli.requests.value.last { $0.url.contains("cancel_booking") }?.body, "{\"classId\":502,\"lateBooking\":true}", "late cancel sends lateBooking:true")
    cli.bookings.value["tok_A"] = classesJSON([(501, isoUTC(openSlot.start)), (502, isoUTC(lateSlot.start)), (hugeId, isoUTC(farSlot.start))])
    counted = try await notifications { try await runCLI(["bookings", "--refresh"]) }
    try assertTrue(counted.code == 0 && counted.notified == 1 && counted.out.contains("\(hugeId)  "), "bookings table prints full 64-bit IDs and notifies once")
    res = try await actionCount { try await runCLI(["cancel", "501", "--late"]) }
    try assertTrue(res.code == 0 && cli.requests.value.last { $0.url.contains("cancel_booking") }?.body == "{\"classId\":501,\"lateBooking\":false}", "--late outside the 3h window sends lateBooking:false")
    cli.bookings.value["tok_A"] = classesJSON([(502, isoUTC(lateSlot.start)), (504, isoUTC(pastSlot.start))])
    _ = try await runCLI(["bookings", "--refresh"])

    cli.classesStatus.value["tok_A"] = 503
    res = try await actionCount { try await runCLI(["book", "501"]) }
    try assertEqual([res.code, Int32(res.actions)], [0, 1], "accepted booking still reports success when refresh fails")
    try assertTrue(res.out.contains("Booked class 501, but refreshing bookings failed") && res.out.contains("Cached bookings were cleared"), "CLI reports partial outcome clearly")
    try assertEqual(cliStore.loadBookings(for: memberA), nil, "partial outcome clears stale bookings cache")
    res = try await actionCount { try await runCLI(["book", "501"]) }
    try assertEqual([res.code, Int32(res.total)], [1, 0], "booking is refused while bookings are out of sync")
    cli.classesStatus.value["tok_A"] = 200
    _ = try await runCLI(["bookings", "--refresh"])
    cli.classesStatus.value["tok_A"] = 401
    res = try await actionCount { try await runCLI(["book", "501"]) }
    try assertTrue(res.code == 0 && res.actions == 1 && res.out.contains("The session token was rejected. The session was cleared"), "accepted booking + 401 refresh exits 0 and says the session was cleared")
    try assertEqual(try cliKC.readSession(), nil, "401 on post-mutation refresh clears the session")
    cli.classesStatus.value["tok_A"] = 200
    try cliKC.saveSession(memberA)
    _ = try await runCLI(["bookings", "--refresh"])

    try cliStore.updatePreferences { $0.searchQuery = "keepme" }
    try assertEqual(try await runCLI(["set-club", "220"]).code, 1, "set-club rejects unentitled club 220")
    try assertEqual(try await runCLI(["set-club", "200"]).code, 0, "set-club accepts entitled club 200")
    try assertEqual([cliStore.loadPreferences().clubId == 200, cliStore.loadPreferences().searchQuery == "keepme"], [true, true], "set-club changes club and keeps other fields")
    try assertEqual(try await captureOutput { await TertiaCLI.run(args: ["set-club", "200"], store: ctx.blockedStore, keychain: cliKC, client: cliPublic, bookingClient: cli.client) }.code, 1, "set-club reports store write failures")
    try cliStore.seedPreferences(TertiaPreferences())

    // 9. MCP: strict JSON-RPC 2.0, exact 64-bit IDs, argument validation, CLI parity
    try assertEqual(await mcp("   "), nil, "blank line ignored")
    try assertEqual(await mcp("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"), nil, "notification returns nil")
    try assertEqual(await mcp("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}"), nil, "request without id key is a notification")
    try assertEqual(try errorCode(await mcp("{not-json")), -32700, "parse error -32700")
    try assertEqual(try errorCode(await mcp("{\"jsonrpc\":\"2.0\",\"id\":1}")), -32600, "missing method -32600")
    try assertEqual(try errorCode(await mcp("{\"id\":1,\"method\":\"ping\"}")), -32600, "missing jsonrpc -32600")
    try assertEqual(try errorCode(await mcp("[1]")), -32600, "non-object request -32600")
    let objId = try decodeJSON(await mcp("{\"jsonrpc\":\"2.0\",\"id\":{\"x\":1},\"method\":\"ping\"}"))
    try assertTrue((objId["error"] as? [String: Any])?["code"] as? Int == -32600 && objId["id"] is NSNull, "object id rejected with id null")
    let nullId = try decodeJSON(await mcp("{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}"))
    try assertTrue(nullId["id"] is NSNull && nullId["result"] != nil, "id null request gets a response")
    try assertEqual(try errorCode(await mcp("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"foo/bar\"}")), -32601, "unknown method -32601")
    try assertEqual(try errorCode(await mcp("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":[1]}")), -32602, "array params -32602")
    try assertEqual(try errorCode(await mcp("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"list_clubs\",\"arguments\":[1]}}")), -32602, "array arguments -32602")
    try assertEqual(try errorCode(await mcp("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":7}}")), -32602, "non-string tool name -32602")
    let bigId = try decodeJSON(await mcp("{\"jsonrpc\":\"2.0\",\"id\":\(hugeId),\"method\":\"ping\"}"))
    try assertEqual((bigId["id"] as? NSNumber)?.int64Value, Int64(hugeId), "64-bit request id echoed exactly")
    for raw in ["9223372036854775808", "9223372036854775809", "18446744073709551615"] {
        try assertTrue((await mcp("{\"jsonrpc\":\"2.0\",\"id\":\(raw),\"method\":\"ping\"}"))?.contains("\"id\":\(raw)") == true, "unsigned 64-bit id \(raw) round-trips losslessly")
    }
    try assertTrue((await mcp("{\"jsonrpc\":\"2.0\",\"id\":18446744073709551616,\"method\":\"ping\"}"))?.hasPrefix("{\"id\":18446744073709551616,") == true, "an id beyond 64 bits is echoed as its exact JSON text")
    try assertTrue(try decodeJSON(await mcp("{\"method\":\"ping\",\"id\":1e3,\"jsonrpc\":\"2.0\"}"))["result"] != nil, "exponent (non-integer literal) id is accepted")
    let notifWithId = try decodeJSON(await mcp("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"notifications/initialized\"}"))
    try assertTrue((notifWithId["error"] as? [String: Any])?["code"] as? Int == -32601 && notifWithId["id"] as? Int == 5, "notification method sent with an id still gets a response")

    let tools = (try decodeJSON(await mcp("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\"}"))["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    try assertEqual(tools.compactMap { $0["name"] as? String }, ["list_clubs", "get_timetable", "set_widget_club", "my_bookings", "book_class", "cancel_booking"], "tools/list exposes 6 tools")
    let clubProp = ((tools[1]["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["club_id"] as? [String: Any]
    try assertEqual(clubProp?["description"] as? String, "Club ID (defaults to active widget club preference)", "get_timetable club_id description")
    let scoped = try JSONDecoder().decode([Club].self, from: Data(try toolResult(await call("list_clubs")).text.utf8))
    try assertEqual(scoped.map(\.id), [39, 200], "list_clubs scoped to the signed-in account")

    let mcpTT = try toolResult(await call("get_timetable", "{\"club_id\":39,\"date\":\"\(openSlot.date)\"}"))
    let cliTT = try await runCLI(["timetable", "--club", "39", "--date", openSlot.date, "--json"])
    struct IdsOnly: Decodable { let classes: [ClassSession] }
    let mcpIds = try JSONDecoder().decode(IdsOnly.self, from: Data(mcpTT.text.utf8)).classes.map(\.id)
    let cliIds = try JSONDecoder().decode(IdsOnly.self, from: Data(cliTT.out.utf8)).classes.map(\.id)
    try assertTrue(!mcpTT.isError && mcpIds == cliIds && mcpIds.contains(501) && (pastSlot.date != openSlot.date || !mcpIds.contains(504)), "CLI and MCP timetable return identical class IDs with zero past grace")
    for (label, args) in [("fractional class_id", "{\"class_id\":1.5}"), ("string class_id", "{\"class_id\":\"501\"}"), ("unknown argument", "{\"class_id\":501,\"force\":true}"), ("missing class_id", "{}")] {
        res = try await actionCount { (0, (try? errorCode(await call("book_class", args))) == -32602 ? "err" : "ok") }
        try assertEqual([res.out, String(res.total)], ["err", "0"], "book_class rejects \(label) as -32602 with zero side effects")
    }
    try assertEqual(try errorCode(await call("get_timetable", "{\"refresh\":\"yes\"}")), -32602, "get_timetable rejects non-boolean refresh (-32602)")
    try assertEqual(try errorCode(await call("book_class", "{\"class_id\":18446744073709551615}")), -32602, "class_id beyond Int is rejected as a non-integer (-32602)")
    try assertEqual(try errorCode(await call("drop_tables")), -32602, "an unknown tool is -32602, not a tool result")
    let initialize = { (params: String) in await mcp("{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"initialize\",\"params\":\(params)}") }
    let initCodes = [try errorCode(await initialize("{}")), try errorCode(await initialize("{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{}}"))]
    let initOK = try decodeJSON(await initialize("{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"verify\"}}"))["result"] as? [String: Any]
    try assertTrue(initCodes == [-32602, -32602] && initOK?["serverInfo"] != nil, "initialize validates protocolVersion, capabilities, and clientInfo.name")
    try assertTrue(try toolResult(await call("book_class", "{\"class_id\":\(hugeId)}")).text.contains("Class \(hugeId) not found"), "64-bit class_id reaches validation exactly")
    res = try await actionCount { (0, try! toolResult(await call("book_class", "{\"class_id\":503}")).text) }
    try assertTrue(res.out.contains("not open for booking yet") && res.total == 0, "MCP book_class enforces the 48h window locally")
    res = try await actionCount { (0, try! toolResult(await call("cancel_booking", "{\"class_id\":502}")).text) }
    try assertTrue(res.out.contains("starts in 3 hours or less") && res.total == 0, "MCP cancel_booking requires late_booking inside 3h")
    res = try await actionCount { (0, try! toolResult(await call("cancel_booking", "{\"class_id\":502,\"late_booking\":true}")).text) }
    try assertTrue(res.out.contains("Cancelled class 502") && res.actions == 1, "MCP late cancel succeeds with late_booking=true")
    cli.classesStatus.value["tok_A"] = 503
    let mcpPartial = try toolResult(await call("book_class", "{\"class_id\":501}"))
    try assertTrue(!mcpPartial.isError && mcpPartial.text.contains("but refreshing bookings failed"), "MCP reports accepted booking with failed refresh")
    try assertTrue(try toolResult(await call("my_bookings")).isError, "my_bookings without cache is an error (CLI parity)")
    cli.classesStatus.value["tok_A"] = 200
    try assertTrue(!(try toolResult(await call("my_bookings", "{\"refresh\":true}")).isError), "my_bookings refresh succeeds")
    try assertTrue(try toolResult(await call("set_widget_club", "{\"club_id\":220}")).isError, "set_widget_club rejects unentitled club")
    try assertTrue(!(try toolResult(await call("set_widget_club", "{\"club_id\":200}")).isError) && cliStore.loadPreferences().clubId == 200, "set_widget_club saves entitled club")
    counted = try await notifications { try await runCLI(["logout"]) }
    try assertEqual([counted.code, Int32(counted.notified)], [0, 1], "logout succeeds and notifies once")
    try assertEqual(try cliKC.readSession(), nil, "logout removed the Keychain session")
    try assertEqual(try JSONDecoder().decode([Club].self, from: Data(try toolResult(await call("list_clubs")).text.utf8)).count, 17, "signed-out list_clubs returns all 17 clubs")

}

@MainActor func publicClient(_ ctx: TestContext) async throws {
    // 10. PublicTimetableClient: club validation, per-date freshness, range replacement
    let pubDir = ctx.scratch("public")
    let pubStore = SharedStateStore(primaryDirectory: pubDir)
    let pub = mockPublicClient(store: pubStore)
    try await assertThrows("club 0 rejected") { _ = try await pub.fetchSchedule(clubId: 0, date: todayIso) }
    MockHTTPBox.shared.set(4242, body: timetableHTML([]))
    try await assertThrows("unknown club rejected, never labelled Canary Wharf") { _ = try await pub.fetchSchedule(clubId: 4242, date: todayIso) }
    try await assertThrows("invalid date rejected before HTTP") { _ = try await pub.fetchSchedule(clubId: 39, date: "2026-02-31") }
    let day2 = LondonCalendar.addDays(to: todayIso, days: 2)!, day9 = LondonCalendar.addDays(to: todayIso, days: 9)!, old = LondonCalendar.addDays(to: todayIso, days: -5)!
    let staleRow = ClassSession(id: 9, date: day2, startTime: "10:00", endTime: "10:45", durationMinutes: 45, title: "Removed", trainer: "", clubName: "Canary Wharf")
    try pubStore.seedSnapshot(TimetableSnapshot(clubs: Club.defaultClubs, clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [day2: [staleRow], day9: [staleRow], old: [staleRow], todayIso: []], syncedAt: Date(), daySyncedAt: [day9: Date(), old: Date()]))
    let before39 = MockHTTPBox.shared.count(39)
    let fresh = try await pub.fetchSchedule(clubId: 39, date: todayIso)
    try assertEqual(MockHTTPBox.shared.count(39), before39 + 1, "snapshot without a stamp for the date is refetched")
    try assertTrue(fresh.days[day2]?.contains { $0.id == 9 } == false, "row omitted from a fetched day is removed")
    try assertEqual(fresh.days[day9]?.count, 1, "dates outside the fetched range are kept")
    try assertTrue(fresh.days[old] == nil && fresh.daySyncedAt[old] == nil, "dates before yesterday are pruned")
    try assertEqual(Set(fresh.daySyncedAt.keys), Set((0...3).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) } + [day9]), "daySyncedAt stamps fetched dates and keeps other stamps")
    _ = try await pub.fetchSchedule(clubId: 39, date: todayIso)
    try assertEqual(MockHTTPBox.shared.count(39), before39 + 1, "fresh per-date cache serves without HTTP")
    let futureDir = ctx.scratch("future")
    let futureStore = SharedStateStore(primaryDirectory: futureDir)
    // A clock that read 00:45 when the cache said 01:30 must not keep a "future" stamp fresh forever.
    try futureStore.seedSnapshot(TimetableSnapshot(clubs: [], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: []], syncedAt: Date().addingTimeInterval(2700), daySyncedAt: [todayIso: Date().addingTimeInterval(2700)]))
    _ = try await mockPublicClient(store: futureStore).fetchSchedule(clubId: 39, date: todayIso)
    try assertEqual(MockHTTPBox.shared.count(39), before39 + 2, "future-dated cache stamp is treated as stale")
    let historical = try await pub.fetchSchedule(clubId: 39, date: old)
    try assertTrue(historical.hasCachedDay(old) && pubStore.loadSnapshot(clubId: 39)?.hasCachedDay(old) == false, "historical query returns its days while disk stays pruned")
    let mergeDir = ctx.scratch("merge")
    let mergeStore = SharedStateStore(primaryDirectory: mergeDir)
    let newerRow = ClassSession(id: 1, date: day2, startTime: "10:00", endTime: "10:45", durationMinutes: 45, title: "Newer", trainer: "", clubName: "Canary Wharf")
    let olderRow = ClassSession(id: 2, date: day2, startTime: "11:00", endTime: "11:45", durationMinutes: 45, title: "Older", trainer: "", clubName: "Canary Wharf")
    let extraClub = Club(id: 300, name: "Zeta New", shortCode: "ZN")
    let olderSeq = try mergeStore.reserveSnapshotSequence(), newerSeq = try mergeStore.reserveSnapshotSequence()
    _ = try mergeStore.mergeAndSaveSnapshot(clubId: 39, clubs: [canary, extraClub], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [day2: [newerRow]], fetchedRange: [day2], requestSeq: newerSeq, syncedAt: Date())
    let merged = try mergeStore.mergeAndSaveSnapshot(clubId: 39, clubs: [], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [day2: [olderRow]], fetchedRange: [day2], requestSeq: olderSeq, syncedAt: Date())
    try assertTrue(merged.classes(for: day2) == [newerRow] && mergeStore.loadSnapshot(clubId: 39)?.classes(for: day2) == [newerRow], "an older overlapping response never clobbers a newer day")
    try assertTrue(mergeStore.publicClubCatalog().count == 18 && mergeStore.publicClubCatalog().contains(extraClub), "public club catalog merges extra non-hidden clubs")
    try assertEqual(try TertiaCLI.availableClubsWithWarning(store: mergeStore, keychain: ctx.keychain("catalog")).clubs.count, 17, "signed-out club list stays the 17 defaults")

}

@MainActor func viewModel(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 11. ScheduleViewModel: Keychain safety, refresh independence, club isolation, races, guards, partial outcomes
    let uiDir = ctx.scratch("ui")
    let uiStore = SharedStateStore(primaryDirectory: uiDir)
    let uiKC = ctx.keychain("ui")
    try loginSeed(uiStore, canaryMember, ctx.keychain("ui-seed"), bookingsA.bookings)
    try seedForeignKeychainItem(service: uiKC.service, account: uiKC.account)
    let ui = MobileMock()
    let uiPublic = mockPublicClient(store: uiStore)
    let unreadable = ScheduleViewModel(store: uiStore, keychain: uiKC, client: uiPublic, bookingClient: ui.client)
    try assertTrue(unreadable.memberSession == nil && unreadable.bannerIsError && fm.fileExists(atPath: uiDir.appendingPathComponent("bookings.json").path), "unreadable Keychain keeps bookings.json, stays signed out, shows error")
    try uiKC.deleteSession()

    try uiStore.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: []], syncedAt: Date().addingTimeInterval(-7200)))
    let vm = ScheduleViewModel(store: uiStore, keychain: uiKC, client: uiPublic, bookingClient: ui.client)
    try assertTrue(vm.memberSession == nil && vm.bookings == nil && !fm.fileExists(atPath: uiDir.appendingPathComponent("bookings.json").path), "signed-out init clears orphaned bookings")
    try assertEqual(vm.availableClubs.count, 17, "signed-out catalog keeps all 17 clubs despite a partial snapshot club list")
    await vm.load(forceRefresh: true)
    try assertTrue(vm.snapshot!.syncedAt > Date().addingTimeInterval(-60) && !vm.isLoading && vm.errorMessage == nil && ui.count == 0, "signed-out refresh loads public timetable with zero private calls")

    vm.emailInput = "a@example.com"; vm.passwordInput = "secret"; vm.isAccountOpen = true
    vm.preferences = TertiaPreferences(clubId: 220, clubName: "Chelsea", clubShortCode: "CHE")
    ui.bookings.value["tok_A"] = classesJSON([(502, isoUTC(lateSlot.start)), (504, isoUTC(pastSlot.start))])
    await vm.signIn()
    try assertTrue(vm.memberSession?.token == "tok_A" && vm.passwordInput.isEmpty && !vm.isAccountOpen && !vm.isAuthBusy, "signIn stores session and closes the panel")
    try assertEqual(vm.preferences.clubId, 39, "signIn aligns disallowed Chelsea to home club")
    try assertEqual(vm.availableClubs.map(\.id), [39, 200], "signed-in clubs scoped to entitlements")
    try assertEqual(vm.bookings?.bookedIds, Set([502, 504]), "signIn syncs bookings")

    // Public 503 must not skip the private refresh; a private failure must not discard a fresh timetable.
    MockHTTPBox.shared.set(39, status: 503, body: "busy")
    var count = ui.count
    await vm.load(forceRefresh: true)
    try assertTrue(ui.count == count + 1 && vm.bookings != nil && vm.bannerIsError && (vm.bannerMessage ?? "").contains("503"), "public 503 still runs the bookings sync and shows the error")
    MockHTTPBox.shared.set(39, body: page39)
    ui.classesStatus.value["tok_A"] = 503
    let syncedBefore = vm.snapshot!.syncedAt
    await vm.load(forceRefresh: true)
    try assertTrue(vm.snapshot!.syncedAt > syncedBefore && vm.memberSession != nil && vm.bannerIsError, "failed bookings sync keeps the fresh public timetable")
    ui.classesStatus.value["tok_A"] = 200
    await vm.load(forceRefresh: true)
    count = ui.count
    await vm.load(forceRefresh: false)
    try assertEqual(ui.count, count, "non-forced load never calls the private API")

    // Execution-time checks (started booked class, 48h window, click-time clock, late-cancel confirmation) on a fixed
    // London clock, run at 12:00 and at 20:00, so no fixture row drifts across midnight whatever the run time.
    for hhmm in ["12:00", "20:00"] {
        let clock = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: hhmm)!
        func fixedRow(_ id: Int, _ offset: TimeInterval, _ title: String) -> ClassSession {
            let s = slot(offset, from: clock)
            return ClassSession(id: id, date: s.date, startTime: s.time, endTime: "23:59", durationMinutes: 45, title: title, trainer: "", clubName: "Canary Wharf")
        }
        let open = fixedRow(501, 5 * 3600, "Open Reformer"), late = fixedRow(502, 2 * 3600, "Late Yoga")
        let started = fixedRow(504, -2 * 3600, "Past Pump"), far = fixedRow(503, 60 * 3600, "Far Ride")
        let f = try ctx.freshVM("click-time-\(hhmm)", seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [activeBooking(502, isoUTC(LondonCalendar.startDate(of: late)!)), activeBooking(504, isoUTC(LondonCalendar.startDate(of: started)!))])
            let days = Dictionary(grouping: [open, late, started, far], by: \.date)
            try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: days, syncedAt: clock,
                                                  daySyncedAt: days.mapValues { _ in clock }))
        })
        f.vm.nowOverride = clock
        let count = f.mock.count
        try await pressDisabled(f.vm, started)
        try assertTrue(f.mock.count == count && f.vm.bannerMessage == "Class 504 has already started.", "\(hhmm): booked but started class is blocked")
        try await pressDisabled(f.vm, far)
        try assertTrue(f.mock.count == count && f.vm.bannerIsError, "\(hhmm): class outside 48h is blocked")
        f.vm.selectedDate = open.date
        guard let drawn = f.vm.classAction(for: open, now: clock) else { throw AssertionFailure(description: "FAIL: \(hhmm): row 501 offers Book at \(hhmm)") }
        f.vm.nowOverride = LondonCalendar.startDate(of: open)!.addingTimeInterval(1)
        await drawn()
        try assertTrue(f.mock.count == count && f.vm.bannerMessage == "Class 501 has already started.", "\(hhmm): check uses click-time clock (nowOverride), not render time")
        f.vm.nowOverride = clock
        try await click(f.vm, late)
        try assertTrue(f.vm.confirmLateCancelId == 502 && f.mock.count == count, "\(hhmm): first late-cancel click asks confirmation")
        try await click(f.vm, late)
        try assertTrue(f.vm.confirmLateCancelId == nil && f.mock.requests.value[count].body == "{\"classId\":502,\"lateBooking\":true}", "\(hhmm): second click sends lateBooking:true")
    }
    let open = ClassSession(id: 501, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Open Reformer", trainer: "", clubName: "Canary Wharf")
    let late = ClassSession(id: 502, date: lateSlot.date, startTime: lateSlot.time, endTime: "23:59", durationMinutes: 45, title: "Late Yoga", trainer: "", clubName: "Canary Wharf")

    // Overlapping actions are ignored; a disk sync during the mutation is queued and flushed afterwards.
    ui.actionDelay.value = 0.25
    count = ui.count
    let first = Task { try await click(vm, open) }
    try await Task.sleep(nanoseconds: 60_000_000)
    try assertEqual(vm.busyClassId, 501, "first action is in flight")
    try await pressDisabled(vm, late)
    let loginsBefore = ui.logins
    vm.emailInput = "b@example.com"; vm.passwordInput = "valid-password"
    await vm.signIn()
    try assertTrue(ui.logins == loginsBefore && vm.memberSession?.token == "tok_A", "signIn with a valid password is blocked during a class mutation")
    vm.passwordInput = ""
    try uiStore.updatePreferences { $0.searchQuery = "queued" }
    vm.syncFromDisk()
    try assertTrue(vm.preferences.searchQuery != "queued", "syncFromDisk deferred while busy")
    try await first.value
    ui.actionDelay.value = 0
    try assertEqual(ui.actions(after: count).count, 1, "overlapping class action and sign-in made no extra API calls")
    try assertEqual(vm.preferences.searchQuery, "queued", "pending disk sync flushed after the mutation")
    try uiStore.updatePreferences { $0.searchQuery = "" }
    vm.syncFromDisk()

    // Accepted mutation + failed refresh: bookings unknown, actions disabled until Refresh.
    ui.classesStatus.value["tok_A"] = 503
    try await click(vm, open)
    try assertTrue(vm.bookings == nil && vm.bannerIsError && (vm.bannerMessage ?? "").hasPrefix("Booked Open Reformer at \(openSlot.time), but refreshing bookings failed"), "UI reports accepted booking with failed refresh")
    count = ui.count
    try await pressDisabled(vm, open)
    try assertTrue(ui.count == count && (vm.bannerMessage ?? "").contains("Refresh"), "actions blocked while booking state is unknown")
    ui.classesStatus.value["tok_A"] = 200
    await vm.load(forceRefresh: true)
    try assertTrue(vm.bookings != nil, "Refresh restores bookings")

    // Club switch isolation and out-of-order loads.
    MockHTTPBox.shared.set(200, status: 503, body: "slow", delay: 0.3)
    vm.selectClub(woodWharf)
    try assertTrue(vm.snapshot == nil && vm.preferences.clubName == "Wood Wharf", "club switch never shows the previous club's snapshot")
    try await Task.sleep(nanoseconds: 50_000_000)
    vm.selectClub(canary)
    try assertEqual(vm.snapshot?.clubId, 39, "switching back shows the cached club 39 snapshot")
    try await Task.sleep(nanoseconds: 450_000_000)
    try assertTrue(vm.snapshot?.clubId == 39 && vm.errorMessage == nil && !vm.isLoading, "late club 200 response cannot overwrite snapshot, error, or loading state")
    MockHTTPBox.shared.set(200, body: timetableHTML([Fx(id: 601, slot: openSlot, title: "Wood Wharf Ride", club: "Wood Wharf")]))

    // Account A's delayed response (success or 401) cannot overwrite or sign out account B.
    for delayedStatus in [200, 401] {
        ui.classesDelay.value["tok_A"] = nil; ui.classesStatus.value["tok_A"] = 200
        if vm.memberSession?.token != "tok_A" { vm.emailInput = "a@example.com"; vm.passwordInput = "x"; await vm.signIn() }
        try assertEqual(vm.memberSession?.token, "tok_A", "A signed in before the race")
        ui.classesDelay.value["tok_A"] = 0.3; ui.classesStatus.value["tok_A"] = delayedStatus
        drain(ui.classesArrived)
        let slowRefresh = Task { await vm.load(forceRefresh: true) }
        try assertTrue(await waitFor(ui.classesArrived), "A's delayed bookings request reached the mock before B signs in")
        vm.emailInput = "b@example.com"; vm.passwordInput = "x"
        ui.bookings.value["tok_B"] = classesJSON([(601, isoUTC(openSlot.start))])
        await vm.signIn()
        await slowRefresh.value
        ui.classesDelay.value["tok_A"] = nil
        try assertTrue(vm.memberSession?.token == "tok_B" && uiKC.readSession()?.token == "tok_B", "late A response (\(delayedStatus)) leaves B signed in")
        try assertTrue(vm.bookings?.bookedIds == [601] && uiStore.loadBookedIds() == [601], "late A response (\(delayedStatus)) never replaces B's bookings")
    }
    ui.classesStatus.value["tok_A"] = 200
    vm.signOut()
    try assertTrue(vm.memberSession == nil && uiKC.readSession() == nil, "signOut clears session")
    try uiKC.saveSession(memberA)
    ui.classesStatus.value["tok_A"] = 401
    vm.syncFromDisk()
    try assertEqual(vm.memberSession?.token, "tok_A", "syncFromDisk picks up the Keychain session")
    await vm.load(forceRefresh: true)
    try assertTrue(vm.memberSession == nil && vm.isAccountOpen && uiKC.readSession() == nil && uiStore.loadBookings(for: memberA) == nil, "current-session 401 signs out and clears state")
    vm.selectedDate = "2020-01-01"
    vm.syncFromDisk()
    try assertEqual(vm.selectedDate, todayIso, "syncFromDisk rolls stale selectedDate to London today")

    // Ordering: a sign-out during the public fetch cancels the private sync; an older refresh never undoes a booking.
    ui.classesStatus.value["tok_A"] = 200
    try uiKC.saveSession(memberA); vm.syncFromDisk()
    await vm.load(forceRefresh: true)
    MockHTTPBox.shared.set(39, body: page39, delay: 0.3)
    count = ui.count
    let pausedRefresh = Task { await vm.load(forceRefresh: true) }
    try await Task.sleep(nanoseconds: 80_000_000)
    vm.signOut()
    await pausedRefresh.value
    try assertTrue(ui.count == count && vm.memberSession == nil, "sign-out while the public fetch is paused makes zero private requests")
    MockHTTPBox.shared.set(39, body: page39)
    vm.emailInput = "a@example.com"; vm.passwordInput = "secret"
    ui.bookings.value["tok_A"] = classesJSON([(502, isoUTC(lateSlot.start))])
    await vm.signIn()
    ui.classesDelay.value["tok_A"] = 0.4
    let preBookingRefresh = Task { await vm.load(forceRefresh: true) }
    try await Task.sleep(nanoseconds: 150_000_000)
    ui.classesDelay.value["tok_A"] = nil
    ui.bookings.value["tok_A"] = classesJSON([(501, isoUTC(openSlot.start)), (502, isoUTC(lateSlot.start))])
    try await click(vm, open)
    await preBookingRefresh.value
    try assertTrue(vm.bookings?.bookedIds == [501, 502] && uiStore.loadBookings(for: memberA)?.bookedIds == [501, 502], "a refresh that started before the booking finishes last without undoing it (memory and disk)")

    // Another process switching accounts resets the previous account's confirmation, inputs, and banner.
    try await click(vm, late)
    try assertTrue(vm.isConfirmingLateCancel(502), "late-cancel confirmation armed for A")
    vm.passwordInput = "typed"
    try uiKC.saveSession(MemberSession(token: "tok_B", id: 8, name: "B", email: "b@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary]))
    vm.syncFromDisk()
    try assertTrue(vm.confirmLateCancelId == nil && vm.passwordInput.isEmpty && vm.emailInput == "b@example.com" && vm.bannerMessage == nil && vm.bookings == nil, "external account switch clears A's confirmation, inputs, banner, and bookings")
    try uiKC.deleteSession(); vm.syncFromDisk()

    // Exact notifications, failed preference saves, sign-out cleanup errors, and memberships without timetable clubs.
    let countedDir = ctx.scratch("ui-counted"), countedMirror = ctx.scratch("ui-counted-mirror"), countedKC = ctx.keychain("ui-counted")
    let countedStore = SharedStateStore(primaryDirectory: countedDir, mirrorDirectory: countedMirror)
    let uiNotified = Locked(0)
    let cvm = ScheduleViewModel(store: countedStore, keychain: countedKC, client: mockPublicClient(store: countedStore), bookingClient: ui.client) { uiNotified.mutate { $0 += 1 } }
    cvm.emailInput = "a@example.com"; cvm.passwordInput = "secret"
    ui.classesDelay.value["tok_A"] = 0.3
    let loginsBeforeBusy = ui.logins
    let firstSignIn = Task { await cvm.signIn() }
    try await Task.sleep(nanoseconds: 80_000_000)
    cvm.passwordInput = "another-valid-password"
    await cvm.signIn()
    await firstSignIn.value
    ui.classesDelay.value["tok_A"] = nil
    try assertTrue(cvm.isAuthBusy == false && ui.logins == loginsBeforeBusy + 1, "a second signIn with a valid password is ignored while the first is busy")
    try assertEqual(uiNotified.value, 2, "signIn notifies for the credential and the synced bookings")
    try "{broken".write(to: countedDir.appendingPathComponent("preferences.json"), atomically: true, encoding: .utf8)
    uiNotified.value = 0
    cvm.selectPeriod(.evening)
    try assertTrue(cvm.preferences.period == .all && cvm.bannerIsError && uiNotified.value == 0, "a failed preference save keeps preferences and skips onStateChanged")
    try fm.removeItem(at: countedDir.appendingPathComponent("preferences.json"))
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: countedMirror.path)
    cvm.signOut()
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: countedMirror.path)
    try assertTrue(cvm.memberSession == nil && cvm.bookings == nil && (try countedKC.readSession()) == nil && cvm.bannerIsError && (cvm.bannerMessage ?? "").contains("clearing cached bookings failed") && uiNotified.value == 1,
                   "sign-out deletes the credential first and reports a cache cleanup failure without staying signed in")
    cvm.emailInput = "none@example.com"; cvm.passwordInput = "secret"
    await cvm.signIn()
    try assertTrue(cvm.memberSession?.token == "tok_N" && cvm.snapshot == nil && cvm.errorMessage == ScheduleViewModel.noClubsMessage && !cvm.canUseBookingActions && cvm.availableClubs.isEmpty,
                   "membership without timetable clubs clears the timetable and disables booking")
    try countedKC.deleteSession()

}

@MainActor func widgetHarnessBinary(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 12. Widget data rules
    try assertEqual(widgetUpcomingSessions(snapshot: nil, preferences: TertiaPreferences(), now: Date()), [], "nil snapshot yields no widget rows (no sample data)")
    try assertEqual(widgetUpcomingSessions(snapshot: preview, preferences: TertiaPreferences(), now: previewNow).count, 6, "shared widget filter returns today's upcoming rows")
    let sevenAM = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "07:00")!
    try assertEqual(widgetUpcomingSessions(snapshot: preview, preferences: TertiaPreferences(), now: sevenAM).first?.startTime, "09:30", "a class leaves the widget at its exact start")
    try assertEqual(widgetTimelineDates(snapshot: dupStart, preferences: TertiaPreferences(), now: previewNow).map(LondonCalendar.formatSyncTime), ["06:00", "06:20", "06:40"], "timeline: one entry per distinct start inside 45 minutes, at the exact start")
    let lateEvening = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "23:40")!
    try assertEqual(widgetTimelineDates(snapshot: nil, preferences: TertiaPreferences(), now: lateEvening).last, LondonCalendar.nextMidnight(after: lateEvening), "timeline adds the London midnight rollover")
    try assertEqual([widgetEmptyText(snapshot: yesterdayOnly, preferences: TertiaPreferences(), now: previewNow, clubEmpty: "No more classes today"),
                     widgetEmptyText(snapshot: dupStart, preferences: TertiaPreferences(), now: previewNow, clubEmpty: "No more classes today")],
                    ["Timetable unavailable", "No more classes today"], "missing today reads as unavailable, a cached today as the club wording")

    // 13. Subprocess harness: concurrent drains and a per-child deadline
    let noisy = try runSubprocess("/bin/sh", args: ["-c", "head -c 200000 /dev/zero | tr '\\0' e >&2; echo done"])
    try assertTrue(noisy.stderr.count == 200_000 && noisy.stdout == "done\n" && !noisy.timedOut, "runSubprocess drains >64KB stderr without deadlock")
    let started = Date()
    let hung = try runSubprocess("/bin/sleep", args: ["5"], timeoutSeconds: 0.3)
    try assertTrue(hung.timedOut && Date().timeIntervalSince(started) < 2, "runSubprocess kills a child past its deadline")
    let closedStreams = try runSubprocess("/bin/sh", args: ["-c", "exec >&- 2>&-; exec /bin/sleep 5"], timeoutSeconds: 0.3)
    try assertTrue(closedStreams.timedOut && Date().timeIntervalSince(started) < 4, "a child that closes its streams and sleeps is still killed at the deadline")
    let grandchildStart = Date()
    let backgrounded = try runSubprocess("/bin/sh", args: ["-c", "/bin/sleep 10 & echo $!; echo done"], timeoutSeconds: 0.5)
    let grandchild = pid_t(backgrounded.stdout.split(separator: "\n").first ?? "") ?? 0
    var grandchildGone = false
    for _ in 0..<200 where !grandchildGone { grandchildGone = kill(grandchild, 0) != 0 && errno == ESRCH; if !grandchildGone { usleep(10_000) } }
    try assertTrue(backgrounded.status == 0 && backgrounded.timedOut && backgrounded.stdout.hasSuffix("\ndone\n") && grandchild > 0 && grandchildGone
                   && Date().timeIntervalSince(grandchildStart) < 4.5,
                   "a zero-status child whose 10s background grandchild holds stdout past a 0.5s deadline reads as timed out, and that owned grandchild is killed and reaped")

    // 14. Unified TertiaApp binary: isolated self-test, previews, symlink CLI, architecture
    // Behavioral checks run the shipped executable (test.sh points TERTIA_APP_BIN at dist/Tertia.app/Contents/MacOS/Tertia).
    let rawAppBin = ProcessInfo.processInfo.environment["TERTIA_APP_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "dist/Tertia.app/Contents/MacOS/Tertia"
    let appBin = URL(fileURLWithPath: rawAppBin, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath)).standardizedFileURL.path
    try assertTrue(fm.isExecutableFile(atPath: appBin), "TertiaApp binary exists at \(appBin)")
    try assertTrue(try runSubprocess("/usr/bin/lipo", args: ["-archs", appBin]).stdout.contains("arm64"), "TertiaApp is an arm64 binary")
    let childTmp = ctx.scratch("child-tmp")
    try fm.createDirectory(at: childTmp, withIntermediateDirectories: true)
    let alive = try runSubprocess(appBin, args: ["--self-test-mainactor"], env: ["TMPDIR": childTmp.path + "/"])
    try assertTrue(alive.status == 0 && !alive.timedOut && alive.stdout.contains("MAINACTOR_ALIVE ISOLATED_STORE=1"), "@MainActor self-test runs on an isolated store")
    let previewOut = ctx.scratch("previews")
    let previews = try runSubprocess(appBin, args: ["render-previews", "--offline", "--out", previewOut.path], env: ["TMPDIR": childTmp.path + "/"], timeoutSeconds: 20)
    try assertTrue(previews.status == 0 && !previews.timedOut, "offline render-previews exits 0")
    ctx.renderedPreviews = (previewOut, previews.stdout)
    let pngSizes: [String: (Int, Int)] = [
        "menubar-booking-dark.png": (784, 1120), "menubar-dark.png": (784, 1120), "menubar-club-open-dark.png": (784, 1120), "menubar-light.png": (784, 1120),
        "widget-small-dark.png": (340, 340), "widget-medium-dark.png": (728, 340), "widget-medium-light.png": (728, 340), "widget-large-dark.png": (728, 764),
    ]
    try assertEqual(Set(try fm.contentsOfDirectory(atPath: previewOut.path).filter { $0.hasSuffix(".png") }), Set(pngSizes.keys), "offline render-previews writes the 8 named PNGs")
    for (name, size) in pngSizes {
        let rep = NSBitmapImageRep(data: try Data(contentsOf: previewOut.appendingPathComponent(name)))
        try assertTrue(rep?.pixelsWide == size.0 && rep?.pixelsHigh == size.1, "\(name) decodes as a \(size.0)x\(size.1) PNG")
    }
    try assertTrue(previews.stdout.contains("menubar-booking-dark.png badge: BOOKED · CANCEL"), "the signed-in preview renders BOOKED · CANCEL")
    try assertTrue(previews.stdout.contains("preview clock: now 06:00, synced 06:00"), "offline previews are synced at 06:00, never after the shown 06:00 clock")
    try assertEqual(try fm.contentsOfDirectory(atPath: childTmp.path), [], "self-test and previews remove their temporary stores")
    let symURL = ctx.scratch("sym").appendingPathComponent("tertia")
    try fm.createDirectory(at: symURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: symURL.path, withDestinationPath: appBin)
    let symHelp = try runSubprocess(symURL.path, args: [])
    try assertTrue(symHelp.status == 0 && !symHelp.timedOut && symHelp.stdout.contains("Commands:"), "tertia symlink prints usage")
    let symBogus = try runSubprocess(symURL.path, args: ["bogus-cmd"])
    try assertTrue(symBogus.status == 1 && symBogus.stderr.contains("unknown command 'bogus-cmd'"), "tertia symlink rejects unknown command")
    try assertEqual(try runSubprocess(appBin, args: ["--version"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines), "tertia 0.1.0", "--version output exact")
    let bundledHelper = URL(fileURLWithPath: appBin).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/tertia").path
    if appBin.hasSuffix("Contents/MacOS/Tertia") {
        let helper = try runSubprocess(bundledHelper, args: ["version"])
        try assertTrue(try fm.destinationOfSymbolicLink(atPath: bundledHelper) == "../MacOS/Tertia" && helper.status == 0 && !helper.timedOut && helper.stdout == "tertia 0.1.0\n",
                       "the bundled Contents/Helpers/tertia symlink runs the shipped binary as the CLI")
    }
    try assertTrue(try runSubprocess(appBin, args: ["render-previews", "--help"]).stdout.contains("usage: tertia render-previews"), "render-previews --help")
    try assertEqual(try runSubprocess(appBin, args: ["render-previews", "--bogus"]).status, 1, "render-previews rejects unknown option")

}

@MainActor func accountIsolation(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 16. Account and mutation isolation: paused fetches, racing callers, stale sign-out, expiry outcomes, cleanup

    // A CLI `book` paused in its public fetch, then a logout or an A->B switch from another store: zero private requests.
    MockHTTPBox.shared.set(200, body: timetableHTML([Fx(id: 601, slot: openSlot, title: "Wood Wharf Ride", club: "Wood Wharf")]), delay: 0.3)
    for replacement in [nil, memberB] as [MemberSession?] {
        let dir = ctx.scratch("paused-cli"), kcP = ctx.keychain("paused-cli"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock()
        try st.updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" }
        try loginSeed(st, memberA, kcP, [])
        let pending = Task { try await TertiaCLI.performMutation(classId: 601, isCancel: false, late: false, store: st, keychain: kcP, client: mockPublicClient(store: st), bookingClient: mock.client) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let other = SharedStateStore(primaryDirectory: dir)
        if let replacement { _ = try other.commitLogin(replacement, keychain: kcP) } else { _ = try other.clearSession(keychain: kcP) }
        let result = await pending.result
        try assertTrue(mock.count == 0 && (try? result.get()) == nil, "CLI book paused in its public fetch sends 0 private requests after \(replacement == nil ? "logout" : "an A->B switch")")
    }
    MockHTTPBox.shared.set(200, body: timetableHTML([Fx(id: 601, slot: openSlot, title: "Wood Wharf Ride", club: "Wood Wharf")]))

    // The same for a UI Refresh paused in its public fetch.
    for replacement in [nil, memberB] as [MemberSession?] {
        let f = try ctx.freshVM("paused-ui")
        await signIn(f.vm)
        MockHTTPBox.shared.set(39, body: page39, delay: 0.3)
        let before = f.mock.count
        let paused = Task { await f.vm.load(forceRefresh: true) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let other = SharedStateStore(primaryDirectory: f.dir)
        if let replacement { _ = try other.commitLogin(replacement, keychain: f.kc) } else { _ = try other.clearSession(keychain: f.kc) }
        await paused.value
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(f.mock.count == before && f.vm.memberSession?.token == replacement?.token, "UI Refresh paused in its public fetch sends 0 private requests and shows the current account (\(replacement?.token ?? "signed out"))")
    }

    // Two callers racing `book` on one class: one book_class request, the second is rejected as already booked.
    do {
        let dir = ctx.scratch("race"), kcR = ctx.keychain("race"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock()
        try loginSeed(st, memberA, kcR, [])
        try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [openSlot.date: [open501]], syncedAt: Date(), daySyncedAt: [openSlot.date: Date()]))
        mock.bookings.value["tok_A"] = classesJSON([(501, isoUTC(openSlot.start))])
        mock.actionDelay.value = 0.2
        let pub = mockPublicClient(store: st)
        let racers = (0..<2).map { _ in Task { try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: st, keychain: kcR, client: pub, bookingClient: mock.client) } }
        var results: [Result<String, Error>] = []
        for racer in racers { results.append(await racer.result) }
        let booked = results.compactMap { try? $0.get() }, denied = results.compactMap { if case .failure(let e) = $0 { e.localizedDescription } else { nil } }
        try assertTrue(mock.requests.value.filter { $0.url.contains("book_class") }.count == 1 && booked.count == 1 && denied.first?.contains("already booked") == true,
                       "racing book callers send exactly 1 book_class request; the second is rejected as already booked")
    }

    // A stale UI sign-out after another process replaced A with B leaves B's credential and cache, and shows B.
    do {
        let f = try ctx.freshVM("stale-signout")
        await signIn(f.vm)
        let other = SharedStateStore(primaryDirectory: f.dir)
        _ = try other.commitLogin(memberB, keychain: f.kc)
        _ = try other.commitSyncedBookings([activeBooking(601, isoUTC(openSlot.start))], for: memberB, started: try other.beginBookingsSync(for: memberB, keychain: f.kc), keychain: f.kc)
        f.vm.signOut()
        try assertTrue(try f.kc.readSession()?.token == "tok_B" && f.store.loadBookings(for: memberB)?.bookedIds == [601] && f.vm.memberSession?.token == "tok_B",
                       "stale sign-out keeps B's credential and cache and reloads B")
    }

    // Same member re-login (tok_2) while tok_1's post-mutation refresh fails: tok_2's own bookings ([502], seeded before
    // tok_1's failure lands) survive in account.json, bookings.json, and the widget mirror, byte for byte.
    let a1 = MemberSession(token: "tok_1", id: 7, name: "A", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
    let a2 = MemberSession(token: "tok_2", id: 7, name: "A", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
    do {
        let dir = ctx.scratch("relogin"), mdir = ctx.scratch("relogin-mirror"), kcS = ctx.keychain("relogin"), mock = MobileMock()
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        try loginSeed(st, a1, kcS, [activeBooking(503, isoUTC(farSlot.start))])
        mock.classesStatus.value["tok_1"] = 503; mock.classesDelay.value["tok_1"] = 0.3
        drain(mock.classesArrived)
        let mutation = Task { try await mock.client.mutateAndSync(classId: 501, isCancel: false, session: a1, store: st, keychain: kcS) { _, _, _ in false } }
        try assertTrue(await waitFor(mock.classesArrived), "tok_1's follow-up refresh is in flight")
        let other = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        _ = try other.commitLogin(a2, keychain: kcS)
        // tok_1's mutation still holds `.mutation.lock`, so tok_2's seed commits as that lock's follow-up.
        let started = try other.beginBookingsSync(for: a2, keychain: kcS, completingMutation: true)
        _ = try other.commitSyncedBookings([activeBooking(502, isoUTC(lateSlot.start))], for: a2, startedAtRevision: started.startedAtRevision, syncSeq: started.syncSeq,
                                           keychain: kcS, completingMutation: true)
        let files = [dir.appendingPathComponent("account.json"), dir.appendingPathComponent("bookings.json"), mdir.appendingPathComponent("bookings.json")]
        let seeded = files.map { try? Data(contentsOf: $0) }
        guard case .acceptedRefreshFailed(_, followUp: .cacheCleanup(.superseded)) = try await mutation.value else { throw AssertionFailure(description: "FAIL: tok_1 refresh should fail as superseded") }
        try assertTrue(try kcS.readSession()?.token == "tok_2" && !seeded.contains(nil) && files.map({ try? Data(contentsOf: $0) }) == seeded
                       && st.loadBookings(for: a2)?.bookedIds == [502] && SharedStateStore(primaryDirectory: mdir).loadBookedIds() == [502],
                       "a failed tok_1 refresh reports .superseded and leaves tok_2's account.json, bookings.json, and widget mirror ([502]) untouched")
    }
    // A refresh started before a booking whose own refresh failed never restores the pre-booking cache.
    do {
        let dir = ctx.scratch("pre-refresh"), kcS = ctx.keychain("pre-refresh"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock()
        try loginSeed(st, a1, kcS, [])
        mock.bookings.value["tok_1"] = classesJSON([(502, isoUTC(lateSlot.start))]); mock.classesDelay.value["tok_1"] = 0.3
        let preRefresh = Task { try await mock.client.syncBookings(for: a1, store: st, keychain: kcS) }
        try await Task.sleep(nanoseconds: 100_000_000)
        mock.classesDelay.value["tok_1"] = nil; mock.classesStatus.value["tok_1"] = 503
        guard case .acceptedRefreshFailed = try await mock.client.mutateAndSync(classId: 501, isCancel: false, session: a1, store: st, keychain: kcS, authorize: { _, _, _ in false }) else {
            throw AssertionFailure(description: "FAIL: post-booking refresh should fail")
        }
        let late = await preRefresh.result
        try assertTrue(st.loadBookings(for: a1) == nil && (late.error as? BookingClientError) == .staleRefresh, "a pre-booking refresh finishing last is discarded (staleRefresh), cache stays invalidated")
    }

    // SessionExpiryOutcome on a 401 during the login sync and during a mutation's follow-up sync.
    for trigger in ["login", "mutation"] {
        for outcome in ["cleared", "superseded", "failed"] {
            let statuses = Locked<[Int32]>([]), notes = Locked(0)
            let hooks = KeychainStore.Hooks(getInteractionAllowed: {
                var status: Int32 = 0
                statuses.mutate { if !$0.isEmpty { status = $0.removeFirst() } }
                return (status, true)
            })
            let f = try ctx.freshVM("expiry-\(trigger)-\(outcome)", hooks: hooks, onChange: { notes.mutate { $0 += 1 } })
            f.mock.bookings.value["tok_A"] = classesJSON([(501, isoUTC(openSlot.start))])
            if trigger == "mutation" { await signIn(f.vm) }
            f.mock.classesStatus.value["tok_A"] = 401; f.mock.classesDelay.value["tok_A"] = 0.25
            let before = notes.value
            let running = Task { if trigger == "login" { await signIn(f.vm) } else { try await click(f.vm, open501) } }
            try await Task.sleep(nanoseconds: 100_000_000)
            switch outcome {
            case "superseded": _ = try SharedStateStore(primaryDirectory: f.dir).commitLogin(memberB, keychain: f.kc)
            case "failed": statuses.value = [0, -50] // the token read succeeds, the Keychain delete fails
            default: break
            }
            try await running.value
            let banner = f.vm.bannerMessage ?? "", label = "\(trigger) 401 -> \(outcome)"
            switch outcome {
            case "cleared":
                try assertTrue(f.vm.memberSession == nil && (try f.kc.readSession()) == nil && notes.value > before && banner.contains("The session was cleared"), "\(label): signed out, widget notified")
            case "superseded":
                try assertTrue(f.vm.memberSession?.token == "tok_B" && (try f.kc.readSession())?.token == "tok_B", "\(label): B survives and is shown")
            default:
                try assertTrue(f.vm.memberSession?.token == "tok_A" && f.vm.bookings == nil && (try f.kc.readSession())?.token == "tok_A" && f.vm.bannerIsError
                               && banner.contains("Clearing the rejected Keychain token failed"), "\(label): the still-stored session stays visible and the error is reported")
            }
        }
    }

    // Legacy widget mirrors holding a raw email are upgraded on an ordinary launch with zero private requests.
    let emailOnly = MemberSession(token: "tok_E", id: 0, name: "E", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary])
    let legacyPrimary = "{\"ownerKey\":\"email:a@example.com\",\"bookings\":[{\"id\":501,\"title\":\"Class 501\",\"startDate\":\"\",\"clubName\":\"\",\"trainerName\":\"\",\"eventAction\":\"cancel\"}],\"syncedAt\":\"2026-01-01T00:00:00Z\"}"
    for legacyMirror in ["{\"bookedIds\":[501],\"ownerKey\":\"email:a@example.com\"}", legacyPrimary] {
        for markerRevision in [nil, 3] as [Int?] {
            let f = try ctx.freshVM("legacy-mirror", mirror: true, seed: { _, kcV, dir, mdir in
                try kcV.saveSession(emailOnly)
                try legacyPrimary.write(to: dir.appendingPathComponent("bookings.json"), atomically: true, encoding: .utf8)
                let revisionField = markerRevision.map { "\"revision\":\($0)," } ?? ""
                try "{\(revisionField)\"ownerId\":\"\(emailOnly.opaqueOwnerId!)\"}".write(to: dir.appendingPathComponent("account.json"), atomically: true, encoding: .utf8) // legacy marker
                try legacyMirror.write(to: mdir!.appendingPathComponent("bookings.json"), atomically: true, encoding: .utf8)
            })
            let mirrorText = (try? String(contentsOf: f.mirror!.appendingPathComponent("bookings.json"), encoding: .utf8)) ?? ""
            let upgraded = try JSONSerialization.jsonObject(with: Data(contentsOf: f.dir.appendingPathComponent("account.json"))) as? [String: Any] ?? [:]
            if markerRevision == nil {
                try assertTrue(f.mock.count == 0 && !mirrorText.contains("a@example.com") && SharedStateStore(primaryDirectory: f.mirror!).loadBookedIds() == [501]
                               && upgraded["bookingsValid"] as? Bool == true && f.vm.bookings?.bookedIds == [501],
                               "a legacy raw-email mirror with a revision-less marker is upgraded on launch and its bookings load (0 private requests)")
            } else {
                // A revision-stamped marker validates only bookings carrying that revision: the legacy file stays hidden.
                try assertTrue(f.mock.count == 0 && !mirrorText.contains("a@example.com") && SharedStateStore(primaryDirectory: f.mirror!).loadBookedIds() == []
                               && upgraded["revision"] as? Int == 3 && upgraded["bookingsValid"] as? Bool == false && f.vm.bookings == nil,
                               "a legacy marker at revision 3 never validates revision-less bookings; the raw-email mirror is removed (0 private requests)")
            }
        }
    }

    // Partial cleanup: an undeletable bookings.json still loses its account marker; a reused newer cache repairs the mirror.
    do {
        let dir = ctx.scratch("partial"), mdir = ctx.scratch("partial-mirror"), kcC = ctx.keychain("partial")
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        _ = try st.commitLogin(memberA, keychain: kcC)
        let rev = try st.beginBookingsSync(for: memberA, keychain: kcC)
        try syncSeed(st, memberA, kcC, [activeBooking(777, "")])
        try fm.removeItem(at: mdir.appendingPathComponent("bookings.json"))
        let reused = try st.commitSyncedBookings([], for: memberA, started: rev, keychain: kcC)
        try assertTrue(reused.snapshot.bookedIds == [777] && SharedStateStore(primaryDirectory: mdir).loadBookedIds() == [], "an overtaken refresh returns the newer primary cache")
        try st.reconcileAccountMirror(for: memberA, keychain: kcC)
        try assertEqual(SharedStateStore(primaryDirectory: mdir).loadBookedIds(), [777], "launch reconciliation repairs a missing widget bookings mirror offline")
        let pinned = [dir, mdir].map { $0.appendingPathComponent("bookings.json") }
        for url in pinned { try fm.setAttributes([.immutable: true], ofItemAtPath: url.path) }
        let result = try st.clearSession(keychain: kcC)
        for url in pinned { try fm.setAttributes([.immutable: false], ofItemAtPath: url.path) }
        try assertTrue(result.didClear && result.cacheError != nil && fm.fileExists(atPath: pinned[0].path) && st.loadBookedIds() == []
                       && SharedStateStore(primaryDirectory: mdir).loadBookedIds() == [] && (try kcC.readSession()) == nil,
                       "an undeletable bookings.json is reported, but account.json no longer names an owner (no badges)")
    }

    // Keychain: a failed re-add after deleting an unreadable item reports previousSessionLost and clears account files;
    // a transient delete error never runs the security helper.
    do {
        let service = ctx.keychainService("lost"), calls = Locked(0)
        let racing = KeychainStore(service: service, account: "verify", hooks: .init(getInteractionAllowed: {
            var n = 0
            calls.mutate { $0 += 1; n = $0 }
            // Just before SecItemAdd, another item appears, so the add fails with errSecDuplicateItem.
            if n == 5 { _ = try? runSubprocess("/usr/bin/security", args: ["add-generic-password", "-s", service, "-a", "verify", "-w", "racing_item"]) }
            return (0, true)
        }))
        try seedForeignKeychainItem(service: service, account: "verify")
        let dir = ctx.scratch("lost"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, canaryMember, ctx.keychain("lost-seed"), bookingsA.bookings)
        var lost: Error?
        do { _ = try st.commitLogin(memberB, keychain: racing) } catch { lost = error }
        guard case .previousSessionLost? = lost as? KeychainError else { throw AssertionFailure(description: "FAIL: expected previousSessionLost, got \(String(describing: lost))") }
        try assertTrue(!fm.fileExists(atPath: dir.appendingPathComponent("bookings.json").path) && st.loadBookedIds() == [], "previousSessionLost clears the store's account files")
        let marker = ctx.scratch("security-ran"), fakeTool = ctx.scratch("fake-security")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: fakeTool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTool.path)
        let ioKC = KeychainStore(service: service, account: "verify", hooks: .init(statusOverride: -36, securityToolPath: fakeTool.path))
        try assertTrue(denial { try ioKC.deleteSession() } == KeychainError.osStatus(-36).localizedDescription && !fm.fileExists(atPath: marker.path), "errSecIO on delete throws without running /usr/bin/security")
    }

}

@MainActor func clubsMenuWidget(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 17. Clubs, snapshots, menu UI, and widget rules
    do {
        let dir = ctx.scratch("widget-club"), kcW = ctx.keychain("widget-club"), st = SharedStateStore(primaryDirectory: dir)
        try kcW.saveSession(memberB) // B may use club 39 only
        let club = try await TertiaCLI.applyWidgetClub(clubId: 200, store: st, keychain: kcW, client: mockPublicClient(store: st))
        try assertTrue(club == nil && st.loadPreferences().clubId == 39, "applyWidgetClub checks the account in the Keychain at save time")
    }
    do {
        let f = try ctx.freshVM("align-fail")
        let chelseaRow = ClassSession(id: 901, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Chelsea Ride", trainer: "", clubName: "Chelsea")
        f.vm.preferences = TertiaPreferences(clubId: 220, clubName: "Chelsea", clubShortCode: "CHE")
        f.vm.snapshot = TimetableSnapshot(clubs: [chelsea], clubId: 220, clubName: "Chelsea", clubShortCode: "CHE", days: [openSlot.date: [chelseaRow]], syncedAt: Date())
        f.vm.selectedDate = openSlot.date
        try assertEqual(f.vm.filteredClasses().map(\.id), [901], "signed out, the Chelsea row is visible")
        try "{broken".write(to: f.dir.appendingPathComponent("preferences.json"), atomically: true, encoding: .utf8)
        await signIn(f.vm)
        try assertTrue(f.vm.memberSession?.token == "tok_A" && f.vm.preferences.clubId == 220 && f.vm.filteredClasses().isEmpty && f.vm.bannerIsError
                       && (f.vm.bannerMessage ?? "").contains("saving this account's club failed"), "failed realignment hides unentitled rows and keeps the error banner")
    }
    let extra = Club(id: 250, name: "Zeta Extra", shortCode: "ZX")
    let member250 = MemberSession(token: "tok_250", id: 25, name: "Z", email: "z@example.com", homeClubId: 250, homeClubName: "Zeta Extra", expiresAt: "", clubs: [extra])
    do {
        let seeded = try ctx.freshVM("club250-seed", seed: { st, kcV, _, _ in
            try st.seedSnapshot(TimetableSnapshot(clubs: Club.defaultClubs + [extra], clubId: 52, clubName: "Soho", clubShortCode: "SOHO", days: [:], syncedAt: Date()))
            try kcV.saveSession(member250)
        })
        try assertTrue(seeded.vm.availableClubs.map(\.id) == [250] && seeded.vm.preferences.clubId == 250 && seeded.vm.errorMessage == nil, "a non-default club from a stored snapshot is available on upgrade")
        MockHTTPBox.shared.set(Club.defaultClubs[0].id, body: timetableHTML([], clubs: [Club.defaultClubs[0], extra]))
        MockHTTPBox.shared.set(250, body: timetableHTML([Fx(id: 2501, slot: openSlot, title: "Zeta Ride", club: "Zeta Extra")], clubs: [extra]))
        let found = try ctx.freshVM("club250-discover", seed: { _, kcV, _, _ in try kcV.saveSession(member250) })
        let probes = MockHTTPBox.shared.count(Club.defaultClubs[0].id)
        await found.vm.load(forceRefresh: false)
        try assertTrue(found.vm.errorMessage == ScheduleViewModel.noClubsMessage && MockHTTPBox.shared.count(Club.defaultClubs[0].id) == probes, "no club discovery without Refresh")
        await found.vm.load(forceRefresh: true)
        try assertTrue(found.vm.preferences.clubId == 250 && found.vm.availableClubs.map(\.id) == [250] && found.vm.errorMessage == nil && found.vm.snapshot?.clubId == 250
                       && MockHTTPBox.shared.count(Club.defaultClubs[0].id) == probes + 1, "Refresh discovers a newly listed entitled club and loads it")
    }
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("clubs-order"))
        let soho = Club(id: 52, name: "Soho", shortCode: "SOHO"), newClub = Club(id: 301, name: "Newer Club", shortCode: "NC"), oldClub = Club(id: 302, name: "Older Club", shortCode: "OC")
        let seqs = try (0..<200).map { _ in try st.reserveSnapshotSequence() }
        try assertTrue(zip(seqs, seqs.dropFirst()).allSatisfy { $0 < $1 }, "request numbers strictly increase even sub-millisecond apart")
        let older = try st.reserveSnapshotSequence(), newer = try st.reserveSnapshotSequence()
        _ = try st.mergeAndSaveSnapshot(clubId: 52, clubs: [soho, newClub], clubName: "Soho", clubShortCode: "SOHO", fetchedDays: [:], fetchedRange: [todayIso], requestSeq: newer, syncedAt: Date())
        _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [canary, oldClub], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [:], fetchedRange: [todayIso], requestSeq: older, syncedAt: Date())
        try assertTrue(st.publicClubCatalog().contains(newClub) && !st.publicClubCatalog().contains(oldClub), "an older club list finishing last never overwrites a newer one")

        let rollback = SharedStateStore(primaryDirectory: ctx.scratch("rollback")), pubR = mockPublicClient(store: rollback)
        let oldRow = ClassSession(id: 5200, date: todayIso, startTime: "23:59", endTime: "23:59", durationMinutes: 0, title: "Future-stamped", trainer: "", clubName: "Soho")
        try rollback.seedSnapshot(TimetableSnapshot(clubs: [], clubId: 52, clubName: "Soho", clubShortCode: "SOHO", days: [todayIso: [oldRow]], syncedAt: Date().addingTimeInterval(3600), daySyncedAt: [todayIso: Date().addingTimeInterval(3600)]))
        MockHTTPBox.shared.set(52, body: timetableHTML([Fx(id: 5201, slot: openSlot, title: "First request", club: "Soho")], clubs: [soho]), delay: 0.25)
        let firstEntered = DispatchSemaphore(value: 0)
        MockHTTPBox.shared.onEntry(52) { firstEntered.signal() }
        let first = Task { try await pubR.fetchSchedule(clubId: 52, date: todayIso, forceRefresh: true) }
        try assertTrue(await waitFor(firstEntered), "request 1 reached the mock before request 2 is sent")
        MockHTTPBox.shared.set(52, body: timetableHTML([Fx(id: 5202, slot: openSlot, title: "Second request", club: "Soho")], clubs: [soho]))
        let second = try await pubR.fetchSchedule(clubId: 52, date: todayIso, forceRefresh: true)
        let firstSnap = try await first.value
        let stored = rollback.loadSnapshot(clubId: 52)
        try assertTrue(second.classes(for: openSlot.date).map(\.id) == [5202] && firstSnap.classes(for: openSlot.date).map(\.id) == [5202]
                       && stored?.classes(for: openSlot.date).map(\.id) == [5202] && stored?.classes(for: todayIso).contains(oldRow) == false,
                       "after a clock rollback, overlapping fetches are kept in request order (the later request wins)")
    }
    do {
        let dir = ctx.scratch("sym-host"), mdir = ctx.scratch("sym-widget")
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), widget = SharedStateStore(primaryDirectory: mdir)
        let day1 = LondonCalendar.addDays(to: todayIso, days: 1)!, dayW = LondonCalendar.addDays(to: todayIso, days: 5)!, now = Date()
        func row(_ id: Int, _ day: String) -> ClassSession { ClassSession(id: id, date: day, startTime: "10:00", endTime: "10:45", durationMinutes: 45, title: "R\(id)", trainer: "", clubName: "Canary Wharf") }
        try widget.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [dayW: [row(71, dayW)], todayIso: [row(72, todayIso)]],
                                                  syncedAt: now, daySyncedAt: [dayW: now.addingTimeInterval(-1), todayIso: now.addingTimeInterval(-1)]))
        _ = try host.mergeAndSaveSnapshot(clubId: 39, clubs: [], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [todayIso: [row(73, todayIso)], day1: [row(74, day1)]],
                                          fetchedRange: [todayIso, day1], requestSeq: try host.reserveSnapshotSequence(), syncedAt: now.addingTimeInterval(-10))
        let mirrored = widget.loadSnapshot(clubId: 39)
        try assertTrue(mirrored?.classes(for: dayW).map(\.id) == [71] && mirrored?.classes(for: todayIso).map(\.id) == [72] && mirrored?.classes(for: day1).map(\.id) == [74],
                       "host merge keeps a widget-only day and a newer widget day, and adds the host's new day")
        try fm.removeItem(at: mdir.appendingPathComponent("snapshot-39.json"))
        let hits = MockHTTPBox.shared.count(39)
        _ = try await mockPublicClient(store: host).fetchSchedule(clubId: 39, date: todayIso)
        try assertTrue(MockHTTPBox.shared.count(39) == hits && fm.fileExists(atPath: mdir.appendingPathComponent("snapshot-39.json").path), "a primary cache hit repairs a missing widget mirror without HTTP")
    }
    do {
        let dir = ctx.scratch("mismatch"), st = SharedStateStore(primaryDirectory: dir), file = dir.appendingPathComponent("snapshot-39.json")
        try st.seedSnapshot(TimetableSnapshot(clubs: [], clubId: 52, clubName: "Soho", clubShortCode: "SOHO", days: [todayIso: []], syncedAt: Date()))
        try fm.copyItem(at: dir.appendingPathComponent("snapshot-52.json"), to: file)
        func merge39() throws { _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [:], fetchedRange: [todayIso], requestSeq: try st.reserveSnapshotSequence(), syncedAt: Date()) }
        try assertTrue(st.loadSnapshot(clubId: 39) == nil && !denial(merge39).isEmpty, "a snapshot-39.json holding club 52 is rejected on load and merge")
        try "{broken".write(to: file, atomically: true, encoding: .utf8)
        try assertTrue(!denial(merge39).isEmpty && (try String(contentsOf: file, encoding: .utf8)) == "{broken", "an unreadable snapshot throws on merge and is never overwritten")
    }

    // Menu: a public load requested before a no-clubs login never restores rows; the next entitled login loads again.
    do {
        let f = try ctx.freshVM("none-delay")
        MockHTTPBox.shared.set(39, body: page39, delay: 0.3)
        let slowLoad = Task { await f.vm.load(forceRefresh: false) }
        try await Task.sleep(nanoseconds: 80_000_000)
        await signIn(f.vm, "none@example.com")
        await slowLoad.value
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(f.vm.snapshot == nil && f.vm.errorMessage == ScheduleViewModel.noClubsMessage && !f.vm.isLoading, "a response requested before a no-clubs login never restores rows")
        await signIn(f.vm)
        try assertTrue(f.vm.errorMessage == nil && f.vm.snapshot?.clubId == 39, "an entitled login after a no-clubs login clears the error and loads the timetable")
    }
    // Menu: a row captured for club 39 and clicked after switching to cached club 200 sends zero mutations.
    do {
        let f = try ctx.freshVM("stale-row", seed: { st, _, _, _ in
            try st.seedSnapshot(TimetableSnapshot(clubs: [woodWharf], clubId: 200, clubName: "Wood Wharf", clubShortCode: "WW", days: [todayIso: []], syncedAt: Date(), daySyncedAt: [todayIso: Date()]))
        })
        await signIn(f.vm)
        await f.vm.load(forceRefresh: false)
        guard let staleRow = f.vm.snapshot?.days.values.flatMap({ $0 }).first(where: { $0.id == 501 }) else { throw AssertionFailure(description: "FAIL: club 39 row 501 should be loaded") }
        f.vm.selectedDate = staleRow.date
        guard let staleAction = f.vm.classAction(for: staleRow) else { throw AssertionFailure(description: "FAIL: club 39 row 501 offers Book") }
        f.vm.selectClub(woodWharf)
        let before = f.mock.count
        await staleAction()
        try assertTrue(f.vm.snapshot?.clubId == 200 && f.mock.count == before && f.vm.bannerMessage == ScheduleViewModel.staleIntentMessage, "a stale club 39 row clicked after switching to club 200 sends 0 mutations")
    }
    // Menu: London midnight in an open menu moves to today with zero private calls; rows and footer follow the new day.
    do {
        let f = try ctx.freshVM("midnight")
        f.vm.selectedDate = LondonCalendar.addDays(to: todayIso, days: -1)!
        await f.vm.rolloverMidnightIfNeeded(now: Date())
        try assertTrue(f.vm.selectedDate == todayIso && f.mock.count == 0, "midnight rollover selects London today with 0 private calls")
        let tomorrowIso = LondonCalendar.addDays(to: todayIso, days: 1)!
        let lateRow = ClassSession(id: 81, date: todayIso, startTime: "23:50", endTime: "23:59", durationMinutes: 9, title: "Late", trainer: "", clubName: "Canary Wharf")
        let dawnRow = ClassSession(id: 82, date: tomorrowIso, startTime: "07:00", endTime: "07:45", durationMinutes: 45, title: "Dawn", trainer: "", clubName: "Canary Wharf")
        f.vm.snapshot = TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: [lateRow], tomorrowIso: [dawnRow]], syncedAt: Date(), daySyncedAt: [todayIso: Date()])
        let at2349 = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "23:49")!, at2350 = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "23:50")!, midnight = LondonCalendar.nextMidnight(after: at2349)!
        try assertTrue(f.vm.filteredClasses(now: at2349).map(\.id) == [81] && f.vm.filteredClasses(now: at2350).isEmpty && f.vm.filteredClasses(now: midnight).map(\.id) == [82] && f.vm.effectiveSelectedDate(now: midnight) == tomorrowIso,
                       "started class clears at 23:50 and at 00:00 the open menu shows the new day at once (yesterday's rows never reappear)")
        try assertTrue(f.vm.footerStatusText(count: 1, now: at2349).hasPrefix("1 CLASSES · SYNCED ") && f.vm.footerStatusText(count: 1, now: midnight) == "1 CLASSES · NOT SYNCED",
                       "footer reads NOT SYNCED for a day without a sync stamp (never SYNCED --:--)")
    }
    // Booked rows: Cancel follows the booking's own start stamp (fixed London clocks 12:00 and 20:00: the public row 2h
    // before, the booking's own start 3h30m after, both on the clock's date); clock-change rows never offer Book.
    for hhmm in ["12:00", "20:00"] {
        let clock = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: hhmm)!
        let past = slot(-2 * 3600, from: clock), stampStart = slot(3.5 * 3600, from: clock).start
        let startedRow = ClassSession(id: 504, date: past.date, startTime: past.time, endTime: "23:59", durationMinutes: 45, title: "Past Pump", trainer: "", clubName: "Canary Wharf")
        let f = try ctx.freshVM("cancel-stamp-\(hhmm)", seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [activeBooking(504, isoUTC(stampStart))])
            try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [past.date: [startedRow]], syncedAt: clock,
                                                  daySyncedAt: [past.date: clock]))
        })
        f.vm.nowOverride = clock
        try assertTrue(BookingAuthorization.canCancel(classId: 504, bookings: f.vm.bookings, now: clock) { (startedRow, 39, "Canary Wharf") }
                       && f.vm.badge(for: startedRow, now: clock) == .bookedCancel,
                       "\(hhmm): a booked row with a future booking stamp offers Cancel even when the public row reads started")
        let before = f.mock.count
        try await click(f.vm, startedRow)
        try assertEqual(f.mock.actions(after: before).map(\.body), ["{\"classId\":504,\"lateBooking\":false}"], "\(hhmm): that Cancel is sent")
        for (stamp, expected) in [("", false), (isoUTC(past.start), false), ("2026-10-25T01:30:00", false), (isoUTC(stampStart), true)] {
            let bookings = BookingsSnapshot(ownerKey: "id:7", bookings: [activeBooking(504, stamp)], syncedAt: clock)
            try assertEqual(BookingAuthorization.canCancel(classId: 504, bookings: bookings, now: clock) { (startedRow, 39, "Canary Wharf") }, expected, "\(hhmm): canCancel for stamp '\(stamp)'")
        }
    }
    let clockChange = LondonCalendar.parseIsoDate("2026-03-01")!
    for row in [ClassSession(id: 1, date: "2026-10-25", startTime: "01:30", endTime: "02:30", durationMinutes: 60, title: "Autumn", trainer: "", clubName: ""),
                ClassSession(id: 2, date: "2026-03-29", startTime: "01:30", endTime: "02:30", durationMinutes: 60, title: "Spring", trainer: "", clubName: "")] {
        let badge = CompactClassCard.badge(status: LondonCalendar.bookingWindowStatus(for: row, now: clockChange), isBooked: false, canCancelBooked: false, confirmingLateCancel: false, isBusy: false, hasAction: true)
        try assertTrue(badge == .status(.invalidTime) && badge.label == "UNAVAILABLE" && !badge.isAction, "\(row.title) clock-change row shows UNAVAILABLE and never BOOK")
    }
    let badgeCases: [(BookingWindowStatus, Bool, Bool, Bool, CompactClassCard.Badge)] = [
        (.open, false, false, false, .book), (.started, false, false, false, .status(.started)), (.open, true, false, false, .booked),
        (.started, true, true, true, .confirmLateCancel), (.upcoming("OPENS"), false, false, false, .status(.upcoming("OPENS"))),
    ]
    for (status, booked, canCancel, confirming, expected) in badgeCases {
        try assertEqual(CompactClassCard.badge(status: status, isBooked: booked, canCancelBooked: canCancel, confirmingLateCancel: confirming, isBusy: false, hasAction: true), expected, "card badge \(status) booked=\(booked)")
    }
    try assertEqual(CompactClassCard.Badge.status(.started).label, "STARTED", "started card badge renders STARTED")

    // Widget: post-midnight starts inside the 45-minute horizon, filtered-empty copy, and the sync footer.
    do {
        let tomorrowIso = LondonCalendar.addDays(to: todayIso, days: 1)!, at2340 = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "23:40")!
        let crossing = TimetableSnapshot(clubs: [], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: [], tomorrowIso: [
            ClassSession(id: 91, date: tomorrowIso, startTime: "00:10", endTime: "00:55", durationMinutes: 45, title: "Night Owl", trainer: "", clubName: "")]], syncedAt: at2340)
        try assertEqual(widgetTimelineDates(snapshot: crossing, preferences: TertiaPreferences(), now: at2340).map(LondonCalendar.formatSyncTime), ["23:40", "00:00", "00:10"], "23:40 timeline includes 00:00 and the cached 00:10 class")
        let at2100 = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "21:00")!
        let emptyCases: [(TimetableSnapshot?, TertiaPreferences, Date, String)] = [
            (nil, TertiaPreferences(), previewNow, "Timetable unavailable"), (yesterdayOnly, TertiaPreferences(searchQuery: "zzz"), previewNow, "Timetable unavailable"),
            (preview, TertiaPreferences(searchQuery: "zzz"), previewNow, "No classes match filter"), (preview, TertiaPreferences(period: .morning), at2100, "CLUB"),
            (preview, TertiaPreferences(searchQuery: "  "), at2100, "CLUB"), (dupStart, TertiaPreferences(period: .evening), at2100, "CLUB"),
        ]
        for (snap, prefsCase, now, expected) in emptyCases {
            try assertEqual(widgetEmptyText(snapshot: snap, preferences: prefsCase, now: now, clubEmpty: "CLUB"), expected, "widget empty text (\(prefsCase.period), '\(prefsCase.searchQuery)')")
        }
        try assertTrue(widgetSyncLabel(snapshot: nil, now: previewNow) == "NOT SYNCED" && widgetSyncLabel(snapshot: yesterdayOnly, now: previewNow) == "NOT SYNCED"
                       && widgetSyncLabel(snapshot: preview, now: previewNow) == "SYNCED 06:00", "large widget footer: NOT SYNCED unless today has a sync time")
    }

}

@MainActor func edgesTransportPackaging(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    // 18. Parser, MCP, and CLI edge cases
    let parserCases: [(String, String, [Int]?)] = [
        ("compact empty declaration", "<script>let clubs=[];let timetable={};</script>", []),
        ("quoted > inside a script attribute", "<script data-x=\"a>b\">let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {};</script>", [39]),
        ("<scripture> is not a script", "<scripture>let clubs = [{\"id\":1,\"name\":\"Decoy\"}];</scripture><script>let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {};</script>", [39]),
        ("declaration in HTML body text", "<p>let clubs = [{\"id\":1,\"name\":\"Decoy\"}]; let timetable = {};</p>", nil),
        ("quoted <script> decoy in an attribute", "<div data-x=\"<script>let clubs = [{&quot;id&quot;:1}];\"></div><script>let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {};</script>", [39]),
        ("</scripture> inside JS", "<script>var t = \"</scripture>\";\nlet clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {};</script>", [39]),
        ("malformed date key", "<script>let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {\"2026-13-40\":[]};</script>", nil),
        ("non-date key", "<script>let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {\"tomorrow\":[]};</script>", nil),
    ]
    for (label, html, expected) in parserCases {
        let ids = try? HTMLTimetableParser.parse(html: html).clubs.map(\.id)
        try assertEqual(ids, expected, "parser: \(label)")
    }

    let edgeDir = ctx.scratch("cli-edge"), edgeStore = SharedStateStore(primaryDirectory: edgeDir), edgeKC = ctx.keychain("cli-edge"), edge = MobileMock(), edgePublic = mockPublicClient(store: edgeStore)
    func edgeCLI(_ args: [String]) async throws -> (code: Int32, out: String) {
        try await captureOutput { await TertiaCLI.run(args: args, store: edgeStore, keychain: edgeKC, client: edgePublic, bookingClient: edge.client) }
    }
    func edgeMCP(_ line: String) async -> String? { await MCPServer.handleLine(line, store: edgeStore, keychain: edgeKC, client: edgePublic, bookingClient: edge.client) }
    for pair in [["0.123456789012345678901", "0.123456789012345678902"], ["1.0000000000000000001e2", "1.0000000000000000002e2"], ["-1E-30", "-1.0e-30"]] {
        let replies = await [edgeMCP("{\"jsonrpc\":\"2.0\",\"id\":\(pair[0]),\"method\":\"ping\"}"), edgeMCP("{\"jsonrpc\":\"2.0\",\"id\":\(pair[1]),\"method\":\"ping\"}")]
        try assertTrue(replies[0]?.contains("\"id\":\(pair[0])") == true && replies[1]?.contains("\"id\":\(pair[1])") == true, "MCP echoes exact distinct numeric ids \(pair)")
    }
    try assertEqual(try errorCode(await edgeMCP("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_clubs\",\"arguments\":null}}")), -32602, "arguments null is -32602")
    try assertTrue(try toolResult(await edgeMCP("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"list_clubs\"}}")).isError == false, "omitted arguments default to {}")
    let dupId = try decodeJSON(await edgeMCP("{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":2,\"method\":\"ping\"}"))
    try assertTrue((dupId["error"] as? [String: Any])?["code"] as? Int == -32600 && dupId["id"] is NSNull, "duplicate top-level id keys are -32600 with id null")

    let searched = try await edgeCLI(["timetable", "--club", "39", "--date", openSlot.date, "--search", "-h", "--json"])
    try assertTrue(searched.code == 0 && searched.out.contains("\"classes\"") && !searched.out.contains("Commands:"), "timetable --search -h searches for '-h' instead of printing help")
    try assertEqual([try await edgeCLI(["version", "unexpected"]).code, try await edgeCLI(["version"]).code], [1, 0], "version rejects extra arguments")
    let pwFile = ctx.scratch("password")
    try "\nsec\n".write(to: pwFile, atomically: true, encoding: .utf8)
    let savedStdin = dup(STDIN_FILENO), pwFD = Darwin.open(pwFile.path, O_RDONLY)
    dup2(pwFD, STDIN_FILENO); close(pwFD)
    let stdinLogin = try await edgeCLI(["login", "--email", "a@example.com", "--password-stdin"])
    dup2(savedStdin, STDIN_FILENO); close(savedStdin)
    try assertTrue(stdinLogin.code == 0 && edge.requests.value.last { $0.url.contains("/auth/login") }?.body == "{\"email\":\"a@example.com\",\"password\":\"\\nsec\"}",
                   "--password-stdin strips only the final newline (\"\\nsec\\n\" sends \"\\nsec\")")
    try syncSeed(edgeStore, memberA, edgeKC, [activeBooking(504, isoUTC(pastSlot.start)), activeBooking(501, isoUTC(openSlot.start))])
    let edgeCount = edge.count
    let cachedOnly = try await TertiaCLI.memberBookings(refresh: false, store: edgeStore, keychain: edgeKC, bookingClient: edge.client)
    try assertTrue(cachedOnly.snapshot.bookings.map(\.id) == [501] && edge.count == edgeCount, "cached bookings drop started classes with 0 private calls")
    edge.bookings.value["tok_A"] = classesJSON([(504, isoUTC(pastSlot.start)), (501, isoUTC(openSlot.start))])
    let refreshedOnly = try await TertiaCLI.memberBookings(refresh: true, store: edgeStore, keychain: edgeKC, bookingClient: edge.client)
    try assertTrue(refreshedOnly.snapshot.bookings.map(\.id) == cachedOnly.snapshot.bookings.map(\.id) && edge.count == edgeCount + 1, "refreshed and cached bookings apply the identical started-class filter")
    func passwordLogin(_ input: String) async throws -> (code: Int32, body: String?) {
        let before = edge.count
        let res = try await withStdin(ctx, Data(input.utf8)) { try await edgeCLI(["login", "--email", "a@example.com", "--password-stdin"]) }
        return (res.code, edge.requests.value.dropFirst(before).last { $0.url.contains("/auth/login") }?.body)
    }
    for (input, sent) in [("pw\r\n", "pw"), ("pw\n", "pw"), ("\r\n", nil), ("pw\u{1F600}\n", "pw\u{1F600}"), ("pw\u{1F600}\r\n", "pw\u{1F600}"), ("pw\u{1F600}", "pw\u{1F600}")] as [(String, String?)] {
        let result = try await passwordLogin(input)
        let expected = sent.map { "{\"email\":\"a@example.com\",\"password\":\"\($0)\"}" }
        try assertTrue(result.body == expected && (result.code == 0) == (sent != nil), "--password-stdin \(input.debugDescription) sends \(sent.map { $0.debugDescription } ?? "nothing")")
    }

    // 19. curl transport: parent-side deadlines, sanitized child environment, real TLS ClientHello on the wire
    let probe = MobileRequest(method: "GET", url: "http://127.0.0.1:9/", headers: [])
    for (label, script) in [("early-closing reader", "exec 0<&-; exec /bin/sleep 10"), ("stopped child", "kill -STOP $$"), ("held-open output pipe", "/bin/sleep 10 & exit 0")] {
        let began = Date()
        let thrown = denial { _ = try MobileBookingClient.runCurlSync(probe, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", script], timeoutSeconds: 0.5)) }
        try assertTrue(thrown == "Network request timed out." && Date().timeIntervalSince(began) < 2, "curl deadline covers a \(label) (\(String(format: "%.2f", Date().timeIntervalSince(began)))s)")
    }
    let cappedStart = Date()
    let capped = denial { _ = try MobileBookingClient.runCurlSync(probe, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "cat >/dev/null; head -c 200000 /dev/zero"], timeoutSeconds: 3, maxOutputBytes: 1000)) }
    try assertTrue(capped == "Response exceeded maximum size (1000 bytes)." && Date().timeIntervalSince(cappedStart) < 2, "curl output past maxOutputBytes fails fast")
    let heldStart = Date()
    let held = denial { _ = try MobileBookingClient.runCurlSync(probe, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "exec /bin/sleep 10"], timeoutSeconds: 0.5)) }
    try assertTrue(held == "Network request timed out." && Date().timeIntervalSince(heldStart) < 2, "a child holding stdin open without reading still ends within the deadline")
    let childLog = ctx.scratch("child-env")
    setenv("TERTIA_PASSWORD", "env-secret", 1); setenv("UNRELATED_SENTINEL", "keep_off_disk", 1)
    // The child records only its argv and whether TERTIA_PASSWORD is set; no environment value is ever written to disk.
    let childScript = "printf 'ARGV:%s\\nPASSWORD:%s\\n' \"$*\" \"${TERTIA_PASSWORD+SET}\" > '\(childLog.path)'; cat >/dev/null; printf 'ok\\n200'"
    let echoed = try MobileBookingClient.runCurlSync(probe, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", childScript, "curl", "--disable", "--config", "-"], timeoutSeconds: 5))
    unsetenv("TERTIA_PASSWORD"); unsetenv("UNRELATED_SENTINEL")
    let childText = try String(contentsOf: childLog, encoding: .utf8)
    try assertTrue(echoed.status == 200 && childText == "ARGV:--disable --config -\nPASSWORD:\n" && !childText.contains("keep_off_disk") && !childText.contains("env-secret")
                   && MobileBookingClient.sanitizedCurlEnvironment(["TERTIA_PASSWORD": "x", "HOME": "/h", "CURL_SSL_BACKEND": "secure-transport"]) == ["HOME": "/h", "CURL_SSL_BACKEND": "openssl"], "the spawned child gets fixed argv and no TERTIA_PASSWORD")

    let hello = Locked([UInt8]())
    let (tlsPort, tlsServer) = try acceptAndServeBounded(seconds: 4) { conn in
        var bytes = [UInt8]()
        while bytes.count < 5 || bytes.count < 5 + (Int(bytes[3]) << 8 | Int(bytes[4])) { guard let chunk = conn.read() else { break }; bytes += chunk }
        hello.value = bytes
    }
    _ = try? await MobileBookingClient(baseURL: "https://127.0.0.1:\(tlsPort)").login(email: "a@b.com", password: "p")
    await tlsServer.value
    let record = hello.value
    func u16(_ i: Int) -> Int { Int(record[i]) << 8 | Int(record[i + 1]) }
    try assertTrue(record.count > 50 && record[0] == 0x16 && record[5] == 0x01, "captured a TLS ClientHello record")
    var at = 5 + 4 + 2 + 32
    at += 1 + Int(record[at])
    let cipherBytes = u16(at); at += 2
    let ciphers = stride(from: at, to: at + cipherBytes, by: 2).map(u16)
    at += cipherBytes
    at += 1 + Int(record[at])
    let extEnd = at + 2 + u16(at); at += 2
    var extensions: [Int: [UInt8]] = [:]
    while at + 4 <= extEnd { let len = u16(at + 2); extensions[u16(at)] = Array(record[(at + 4)..<(at + 4 + len)]); at += 4 + len }
    let alpn = extensions[0x0010] ?? [], versions = extensions[0x002b] ?? [], groups = extensions[0x000a] ?? []
    func pairs(_ raw: ArraySlice<UInt8>) -> [Int] { stride(from: raw.startIndex, to: raw.endIndex - 1, by: 2).map { Int(raw[$0]) << 8 | Int(raw[$0 + 1]) } }
    var protocols: [String] = [], alpnAt = 2
    while alpnAt < alpn.count { let len = Int(alpn[alpnAt]); protocols.append(String(decoding: alpn[(alpnAt + 1)..<min(alpn.count, alpnAt + 1 + len)], as: UTF8.self)); alpnAt += 1 + len }
    // The expected cipher IDs, group IDs, and ALPN list come only from the reference wire fixture.
    struct WireProfile { var ciphers: [Int]; var groups: [Int]; var alpn: [String] }
    let wireFixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/android-6.7.4-wire-profile.json"))) as? [String: Any] ?? [:]
    func ids(_ key: String) -> [Int] { (wireFixture[key] as? [[String: String]] ?? []).compactMap { $0["id"].flatMap { Int($0.dropFirst(2), radix: 16) } } }
    let reference = WireProfile(ciphers: ids("tlsCiphers"), groups: ids("tlsCurves"), alpn: wireFixture["alpn"] as? [String] ?? [])
    func matchesCapture(_ profile: WireProfile) -> Bool {
        ciphers == profile.ciphers + [0x00ff] && pairs(groups.dropFirst(2)) == profile.groups && protocols == profile.alpn
    }
    try assertTrue(reference.ciphers.count == 15 && reference.groups.count == 3 && reference.alpn == ["h2", "http/1.1"] && matchesCapture(reference),
                   "ClientHello carries exactly the fixture's 15 cipher suites in wire order (plus the renegotiation SCSV), its 3 groups, and its ALPN list")
    var oneCipher = reference; oneCipher.ciphers[3] ^= 0x0001
    var swappedCurves = reference; swappedCurves.groups.swapAt(1, 2)
    try assertTrue(!matchesCapture(oneCipher) && !matchesCapture(swappedCurves), "a fixture copy with one changed cipher ID or two swapped curves no longer matches the captured ClientHello")
    try assertEqual(pairs(versions.dropFirst()), [0x0304, 0x0303], "ClientHello supported_versions is exactly TLS 1.3 then 1.2")

    // 20. Packaging: test.sh packages first into its private TERTIA_DIST_APP from TERTIA_BUILD_DIR, so the bundle under
    // test is the one built from this source (never skipped).
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let env = ProcessInfo.processInfo.environment
    let buildDir = env["TERTIA_BUILD_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build/direct")
    let app = env["TERTIA_DIST_APP"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("dist/Tertia.app")
    let builtApp = buildDir.appendingPathComponent("TertiaApp"), builtWidget = buildDir.appendingPathComponent("TertiaWidget")
    let bundledWidget = app.appendingPathComponent("Contents/PlugIns/TertiaWidget.appex/Contents/MacOS/TertiaWidget")
    try assertTrue(fm.fileExists(atPath: app.path), "the packaged bundle exists (Scripts/test.sh packages it before the suite)")
    func sections(_ url: URL) -> [String: Data]? { try? machOSections(Data(contentsOf: url)) }
    let appSections = try machOSections(Data(contentsOf: builtApp)), widgetSections = try machOSections(Data(contentsOf: builtWidget))
    try assertTrue((appSections["__TEXT,__text"]?.count ?? 0) > 100_000 && sections(app.appendingPathComponent("Contents/MacOS/Tertia")) == appSections,
                   "the bundled Contents/MacOS/Tertia carries every non-signature section of the built TertiaApp (code, strings, constants, data)")
    try assertEqual(sections(bundledWidget), widgetSections, "the bundled TertiaWidget.appex executable carries every non-signature section of the built TertiaWidget")
    // Negative provenance: another binary, one changed string constant, and one changed widget code byte all differ.
    let appBytes = try Data(contentsOf: builtApp), marker = Data("Open on thirdspace.london".utf8)
    guard let markerRange = appBytes.range(of: marker) else { throw AssertionFailure(description: "FAIL: the menu's help string is not in TertiaApp") }
    var editedApp = appBytes; editedApp[markerRange.upperBound - 1] = UInt8(ascii: "X")
    let editedAppSections = try machOSections(editedApp)
    try assertTrue(editedAppSections != appSections && Set(appSections.keys).filter { editedAppSections[$0] != appSections[$0] } == ["__TEXT,__cstring"],
                   "editing one string constant changes exactly __TEXT,__cstring, which the provenance check compares")
    var olderWidget = try Data(contentsOf: builtWidget)
    if let code = widgetSections["__TEXT,__text"], let at = olderWidget.range(of: code.prefix(64))?.lowerBound { olderWidget[at] ^= 0xFF }
    try assertTrue(try machOSections(olderWidget) != widgetSections && widgetSections != appSections, "a substituted widget binary fails the widget provenance check")
    try assertEqual(fm.contents(atPath: app.appendingPathComponent("Contents/Resources/LICENSE").path), fm.contents(atPath: root.appendingPathComponent("LICENSE").path), "bundled LICENSE matches ./LICENSE byte for byte")
    func entitlements(_ bundle: URL) throws -> [String: Any] {
        let res = try runSubprocess("/usr/bin/codesign", args: ["-d", "--entitlements", "-", "--xml", bundle.path])
        try assertTrue(res.status == 0 && !res.timedOut, "codesign reads \(bundle.lastPathComponent)")
        let xml = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return xml.isEmpty ? [:] : (try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any] ?? ["unparsed": xml])
    }
    try assertTrue(try entitlements(app).isEmpty, "the host app is signed with no entitlements (no App Groups, no keychain groups)")
    let widgetEntitlements = try entitlements(app.appendingPathComponent("Contents/PlugIns/TertiaWidget.appex"))
    try assertTrue(Set(widgetEntitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.network.client"] && widgetEntitlements.values.allSatisfy { ($0 as? Bool) == true },
                   "the widget has exactly app-sandbox and network.client")

    // package_app.sh in scratch roots whose build step copies the real Mach-O executables from `.build/direct` into the
    // per-run TERTIA_BUILD_DIR it is given, with fake `codesign` and `iconutil`. The fake
    // iconutil keeps a copy of the per-run iconset (so the @2x deduplication is checked after the run removed it) and,
    // with TERTIA_TAMPER, alters the staged bundle the way a substituted or edited binary would.
    func packageRoot(_ name: String, codesign: String) throws -> URL {
        let pkgRoot = ctx.scratch(name)
        for dir in ["Scripts", "Packaging", ".build/direct", "dist/Tertia.app/Contents", "fake-bin"] { try fm.createDirectory(at: pkgRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Scripts/package_app.sh", "Scripts/publish.py", "Packaging/App-Info.plist", "Packaging/Widget-Info.plist", "LICENSE"] {
            try fm.copyItem(at: root.appendingPathComponent(path), to: pkgRoot.appendingPathComponent(path))
        }
        for built in [builtApp, builtWidget] { try fm.copyItem(at: built, to: pkgRoot.appendingPathComponent(".build/direct/\(built.lastPathComponent)")) }
        try olderWidget.write(to: pkgRoot.appendingPathComponent("older-widget"))
        let iconutil = """
        #!/bin/sh
        here="$(dirname "$0")/.."; stage="$(dirname "$(dirname "$(dirname "$5")")")"
        rm -rf "$here/iconset-capture"; cp -R "$3" "$here/iconset-capture"; : > "$5"
        case "${TERTIA_TAMPER:-}" in
          cstring) /usr/bin/perl -0777 -pi -e 's/Open on thirdspace\\.london/Open on thirdspace.londoX/' "$stage/Contents/MacOS/Tertia" ;;
          widget) cp "$here/older-widget" "$stage/Contents/PlugIns/TertiaWidget.appex/Contents/MacOS/TertiaWidget" ;;
        esac

        """
        let build = "#!/bin/sh\nset -e\nhere=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"; mkdir -p \"$TERTIA_BUILD_DIR\"\n[ \"$TERTIA_BUILD_DIR\" -ef \"$here/.build/direct\" ] || cp \"$here/.build/direct/TertiaApp\" \"$here/.build/direct/TertiaWidget\" \"$TERTIA_BUILD_DIR/\"\n"
        for (path, text) in [("Scripts/build.sh", build), ("fake-bin/codesign", codesign), ("fake-bin/iconutil", iconutil),
                             ("dist/Tertia.app/Contents/PREVIOUS", "previous bundle\n")] {
            try text.write(to: pkgRoot.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pkgRoot.appendingPathComponent(path).path)
        }
        try markTertiaBundle(pkgRoot.appendingPathComponent("dist/Tertia.app"))
        return pkgRoot
    }
    func packageEnv(_ pkgRoot: URL) -> [String: String] {
        ["PATH": "\(pkgRoot.appendingPathComponent("fake-bin").path):/usr/bin:/bin", "TERTIA_BUILD_DIR": pkgRoot.appendingPathComponent(".build/direct").path,
         "TERTIA_DIST_APP": pkgRoot.appendingPathComponent("dist/Tertia.app").path, "TERTIA_LOCK_TIMEOUT": "20", "TERTIA_PACKAGE_BUILD_DIR": ""]
    }
    func keptPrevious(_ pkgRoot: URL) -> Bool { (try? String(contentsOf: pkgRoot.appendingPathComponent("dist/Tertia.app/Contents/PREVIOUS"), encoding: .utf8)) == "previous bundle\n" }

    // A signing failure leaves the previous bundle in place, and the per-run iconset is gone.
    let failRoot = try packageRoot("package-fail", codesign: "#!/bin/sh\necho 'simulated signing failure' >&2\nexit 1\n")
    let failed = try runSubprocess("/bin/bash", args: [failRoot.appendingPathComponent("Scripts/package_app.sh").path], env: packageEnv(failRoot), timeoutSeconds: 20)
    let leftovers = try fm.contentsOfDirectory(atPath: failRoot.appendingPathComponent("dist").path).filter { $0 != "Tertia.app" && $0 != ".Tertia.app.lock" }
    try assertTrue(failed.status != 0 && failed.stderr.contains("simulated signing failure") && leftovers.isEmpty && keptPrevious(failRoot),
                   "a failed signature keeps the previous dist/Tertia.app and leaves no staging or .prev bundle")
    try assertTrue(try fm.contentsOfDirectory(atPath: failRoot.appendingPathComponent(".build/direct").path).allSatisfy { !$0.hasPrefix("AppIcon") }, "the per-run AppIcon iconset is removed on exit")
    let iconset = failRoot.appendingPathComponent("iconset-capture")
    for (a, b) in [("icon_16x16@2x.png", "icon_32x32.png"), ("icon_128x128@2x.png", "icon_256x256.png"), ("icon_256x256@2x.png", "icon_512x512.png")] {
        let left = fm.contents(atPath: iconset.appendingPathComponent(a).path)
        try assertTrue(left != nil && left == fm.contents(atPath: iconset.appendingPathComponent(b).path), "\(a) is byte-identical to \(b)")
    }
    // Staging rejects an edited string constant in the host and a substituted widget before anything is signed.
    for (tamper, expected) in [("cstring", "staged executable differs"), ("widget", "staged widget differs")] {
        let tamperRoot = try packageRoot("package-tamper-\(tamper)", codesign: "#!/bin/sh\n: > \"$(dirname \"$0\")/../signed\"\nexit 0\n")
        let run = try runSubprocess("/bin/bash", args: [tamperRoot.appendingPathComponent("Scripts/package_app.sh").path], env: packageEnv(tamperRoot).merging(["TERTIA_TAMPER": tamper]) { $1 }, timeoutSeconds: 20)
        try assertTrue(run.status != 0 && run.stderr.contains(expected) && keptPrevious(tamperRoot) && !fm.fileExists(atPath: tamperRoot.appendingPathComponent("signed").path),
                       "staging rejects a \(tamper) substitution before signing and keeps the previous bundle")
    }

    // Publishers run in their own process groups. Each group is recorded right after its launch and the gap watcher
    // is stopped by a `defer` registered before the first launch, so a failed launch, a timeout, or a failed assertion
    // never leaves a child or a watcher running.
    let pubRoot = try packageRoot("package-publish", codesign: "#!/bin/sh\nif [ -n \"$TERTIA_HANG_SIGN\" ]; then : > \"$(dirname \"$0\")/../signing-started\"; exec /bin/sleep 10; fi\nexit 0\n")
    let dest = pubRoot.appendingPathComponent("dist/Tertia.app"), script = pubRoot.appendingPathComponent("Scripts/package_app.sh").path
    final class PublisherScope: @unchecked Sendable {
        /// Process groups still tracked, with whether their leader has exited (and been reaped, so its PID may be reused).
        let groups = Locked<[pid_t: Bool]>([:]), watching = Locked(true), gaps = Locked(0), checks = Locked(0), watcherDone = DispatchSemaphore(value: 0)
        init(watch path: String) {
            Thread.detachNewThread { [self] in
                var st = stat()
                while watching.value {
                    if lstat(path, &st) != 0 { gaps.mutate { $0 += 1 } }
                    checks.mutate { $0 += 1 }
                    usleep(200)
                }
                watcherDone.signal()
            }
        }
        /// Records a launched leader (a leader that already exited stays marked exited).
        func track(_ pid: pid_t) { groups.mutate { $0[pid] = $0[pid] ?? false } }
        /// Called on the leader's exit (possibly before `track`): marks it exited, so its reaped PID is never signalled.
        func retire(_ pid: pid_t) { groups.mutate { $0[pid] = true } }
        /// Retires exited groups that have no member left, so a reused process group ID is never signalled either.
        func prune() { groups.mutate { $0 = $0.filter { !$0.value || kill(-$0.key, 0) == 0 } } }
        /// SIGKILL to every still-running group (and to a leader that has not exited, in case it had not yet left the
        /// parent's group); stops the watcher.
        func tearDown() {
            prune()
            for (pgid, leaderExited) in groups.value { kill(-pgid, SIGKILL); if !leaderExited { kill(pgid, SIGKILL) } }
            watching.value = false
        }
        /// `true` once no tracked group has a live member and the watcher thread has exited (polled for up to 3 s).
        func allGone() -> Bool {
            let watcherStopped = watcherDone.wait(timeout: .now() + 3) == .success
            for _ in 0..<300 { prune(); if groups.value.isEmpty { return watcherStopped }; usleep(10_000) }
            return false
        }
    }
    func launchPublisher(_ scope: PublisherScope, _ env: [String: String], perl: String = "/usr/bin/perl") throws -> (process: Process, exited: DispatchSemaphore) {
        let proc = Process(), exited = DispatchSemaphore(value: 0)
        proc.executableURL = URL(fileURLWithPath: perl)
        proc.arguments = ["-e", "setpgrp(0, 0); exec @ARGV", "/bin/bash", script] // own process group, so a kill reaches its children
        proc.environment = ProcessInfo.processInfo.environment.merging(packageEnv(pubRoot).merging(env) { $1 }) { $1 }
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [scope] p in scope.retire(p.processIdentifier); exited.signal() }
        try proc.run()
        scope.track(proc.processIdentifier)
        return (proc, exited)
    }
    let main = PublisherScope(watch: dest.path)
    do {
        defer { main.tearDown() }
        let publishers = try [launchPublisher(main, [:]), launchPublisher(main, [:])]
        let firstDone = await waitFor(publishers[0].exited, seconds: 20), secondDone = await waitFor(publishers[1].exited, seconds: 20)
        try assertTrue(firstDone && secondDone && publishers.allSatisfy { $0.process.terminationStatus == 0 } && fm.fileExists(atPath: dest.appendingPathComponent("Contents/MacOS/Tertia").path)
                       && !fm.fileExists(atPath: dest.appendingPathComponent("Contents/PREVIOUS").path), "two concurrent package_app.sh runs both publish (serialized by dist/.Tertia.app.lock)")
        let hung = try launchPublisher(main, ["TERTIA_HANG_SIGN": "1"])
        let signing = pubRoot.appendingPathComponent("signing-started")
        for _ in 0..<1600 where !fm.fileExists(atPath: signing.path) { try await Task.sleep(nanoseconds: 5_000_000) }
        kill(-hung.process.processIdentifier, SIGKILL)
        let killed = await waitFor(hung.exited, seconds: 3)
        let relock = try runSubprocess("/usr/bin/python3", args: ["-I", pubRoot.appendingPathComponent("Scripts/publish.py").path, "lock", pubRoot.appendingPathComponent("dist/.Tertia.app.lock").path, "/usr/bin/true"], timeoutSeconds: 3)
        try assertTrue(fm.fileExists(atPath: signing.path) && killed && relock.status == 0 && !relock.timedOut && fm.fileExists(atPath: dest.appendingPathComponent("Contents/MacOS/Tertia").path),
                       "a publisher killed mid-signing leaves the published bundle and releases dist/.Tertia.app.lock")
    }
    try assertTrue(main.allGone() && main.gaps.value == 0 && main.checks.value > 100, "dist/Tertia.app existed at every one of \(main.checks.value) checks across concurrent and interrupted publication; no publisher or watcher survives")
    // A second launch that fails, and a first publisher that never finishes, still leave zero children and watchers.
    for failure in ["second launch fails", "first publisher times out"] {
        let scope = PublisherScope(watch: dest.path)
        let thrown = await denialAsync {
            defer { scope.tearDown() }
            let first = try launchPublisher(scope, ["TERTIA_HANG_SIGN": "1"])
            if failure == "second launch fails" { _ = try launchPublisher(scope, [:], perl: "/nonexistent/perl") }
            guard await waitFor(first.exited, seconds: 0.3) else { throw AssertionFailure(description: "publisher timed out") }
        }
        try assertTrue(!thrown.isEmpty && scope.allGone(), "\(failure): the error surfaces and no publisher child or watcher survives (\(thrown))")
    }
    // The package lock cannot be skipped: an untrusted TERTIA_PACKAGE_LOCKED=1 still waits for the lock (here held by
    // another process) and fails at its monotonic timeout without touching the bundle; the lock frees on the holder's exit.
    do {
        let lockRoot = try packageRoot("package-locked", codesign: "#!/bin/sh\n: > \"$(dirname \"$0\")/../signed\"\nexit 0\n")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        holder.arguments = ["-I", lockRoot.appendingPathComponent("Scripts/publish.py").path, "lock", lockRoot.appendingPathComponent("dist/.Tertia.app.lock").path, "/bin/sleep", "8"]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        try await Task.sleep(nanoseconds: 300_000_000)
        let began = Date()
        let blocked = try runSubprocess("/bin/bash", args: [lockRoot.appendingPathComponent("Scripts/package_app.sh").path],
                                        env: packageEnv(lockRoot).merging(["TERTIA_PACKAGE_LOCKED": "1", "TERTIA_LOCK_TIMEOUT": "0.5"]) { $1 }, timeoutSeconds: 10)
        try assertTrue(blocked.status != 0 && blocked.stderr.contains("timed out") && Date().timeIntervalSince(began) < 3 && keptPrevious(lockRoot)
                       && !fm.fileExists(atPath: lockRoot.appendingPathComponent("signed").path), "TERTIA_PACKAGE_LOCKED=1 cannot skip a held package lock; the run times out untouched")
        // A private destination (make test's TERTIA_DIST_APP) has its own lock, so it never waits for dist/.
        let privateApp = lockRoot.appendingPathComponent("private/Tertia.app")
        let separate = try runSubprocess("/bin/bash", args: [lockRoot.appendingPathComponent("Scripts/package_app.sh").path],
                                         env: packageEnv(lockRoot).merging(["TERTIA_DIST_APP": privateApp.path, "TERTIA_LOCK_TIMEOUT": "0.5"]) { $1 }, timeoutSeconds: 15)
        try assertTrue(separate.status == 0 && !separate.timedOut && holder.isRunning && fm.fileExists(atPath: privateApp.appendingPathComponent("Contents/MacOS/Tertia").path) && keptPrevious(lockRoot),
                       "packaging into a private TERTIA_DIST_APP proceeds while dist/.Tertia.app.lock is held (\(separate.stderr.suffix(200)))")
    }

    // A run killed by SIGKILL skips its cleanup: the next run removes `.stage.<pid>` and `.build/pkg.<pid>` folders of dead
    // processes and keeps a live process's own.
    do {
        let cleanRoot = try packageRoot("package-dead-leftovers", codesign: "#!/bin/sh\nexec /usr/bin/codesign \"$@\"\n")
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try probe.run(); probe.waitUntilExit()
        let leftovers = ["dist/.Tertia.app.stage.\(probe.processIdentifier)", ".build/pkg.\(probe.processIdentifier)", ".build/pkg.\(getpid())"].map { cleanRoot.appendingPathComponent($0) }
        for dir in leftovers { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let res = try runSubprocess("/bin/bash", args: [cleanRoot.appendingPathComponent("Scripts/package_app.sh").path], env: packageEnv(cleanRoot).merging(["TERTIA_BUILD_DIR": ""]) { $1 }, timeoutSeconds: 20)
        let app = cleanRoot.appendingPathComponent("dist/Tertia.app")
        let published = ["Contents/MacOS/Tertia", "Contents/PlugIns/TertiaWidget.appex/Contents/MacOS/TertiaWidget"].map { app.appendingPathComponent($0).path }
        let verified = try runSubprocess("/usr/bin/codesign", args: ["--verify", "--deep", "--strict", app.path], timeoutSeconds: 10)
        try assertTrue(res.status == 0 && !res.timedOut && published.allSatisfy { fm.isExecutableFile(atPath: $0) } && verified.status == 0 && !verified.timedOut
                       && !fm.fileExists(atPath: leftovers[0].path) && !fm.fileExists(atPath: leftovers[1].path) && fm.fileExists(atPath: leftovers[2].path),
                       "package_app.sh publishes a signed bundle with both binaries, removes a dead run's .stage.<pid> and .build/pkg.<pid>, and keeps a live process's .build/pkg.<pid> (\(res.stderr.suffix(300)) \(verified.stderr))")
    }

    // 15. README & Cask accuracy
    let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let readme = try String(contentsOf: repoRoot.appendingPathComponent("README.md"), encoding: .utf8)
    let cask = try String(contentsOf: repoRoot.appendingPathComponent("Packaging/Casks/tertia.rb"), encoding: .utf8)
    try assertTrue(readme.contains("Apple Silicon Mac (`arm64`)") && !readme.contains("OWNER/tertia-club") && readme.contains("bookedIds")
                   && !readme.contains("App Groups instead of container mirroring")
                   && cask.contains("https://github.com/evgesha9400/tertia") && !cask.contains("OWNER/"),
                   "README and Cask document arm64, public repo URL, ID-only mirror, and signing accurately")

}

/// Live `/usr/bin/curl` over HTTP/2 (prior knowledge, loopback): exact HEADERS order and values (HPACK decoded) and DATA.
@MainActor func http2WireParity(_ ctx: TestContext) async throws {
    try assertEqual(try hpackDecode([0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff]).map { "\($0.0)=\($0.1)" },
                    [":method=GET", ":scheme=http", ":path=/", ":authority=www.example.com"], "HPACK decoder passes RFC 7541 C.4.1 (Huffman)")
    let captured = Locked<(preface: [UInt8], headerBlock: [UInt8], data: [UInt8])>(([], [], []))
    let (port, server) = try acceptAndServeBounded(seconds: 4) { conn in
        conn.write([0, 0, 0, 0x04, 0, 0, 0, 0, 0]) // empty server SETTINGS
        captured.value = readHTTP2Request(conn)
    }
    let h2 = MobileBookingClient(baseURL: "http://127.0.0.1:\(port)", transport: MobileBookingClient.makeCurlTransport(
        hooks: .init(arguments: ["--disable", "--http2-prior-knowledge", "--config", "-"], timeoutSeconds: 4)))
    _ = try? await h2.login(email: "a@b.com", password: "p@ss")
    await server.value
    let request = captured.value
    try assertEqual(request.preface, Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8), "curl opened HTTP/2 with the client preface")
    let fields = try hpackDecode(request.headerBlock)
    // curl (nghttp2) always orders pseudo-headers :method, :scheme, :authority, :path; it has no option to reorder them.
    let expected = [(":method", "POST"), (":scheme", "http"), (":authority", "127.0.0.1:\(port)"), (":path", "/api/v2/member/auth/login?api-version=2.0"),
                    ("user-agent", "okhttp/4.12.0"), ("accept-encoding", "gzip"), ("x-app-platform", "android"), ("x-app-version", "6.7.4"), ("content-type", "application/json"),
                    ("content-length", "37")]
    try assertEqual(fields.map { "\($0.0): \($0.1)" }, expected.map { "\($0.0): \($0.1)" }, "HTTP/2 HEADERS carry exactly the Android fields in curl order, with no accept")
    try assertEqual(String(decoding: request.data, as: UTF8.self), "{\"email\":\"a@b.com\",\"password\":\"p@ss\"}", "HTTP/2 DATA carries the exact JSON body")
}

/// Loop 4: stale button intents, refresh ordering around an accepted mutation, follow-up cleanup outcomes, lost replies,
/// sign-out at the transport handoff, live rechecks under `.mutation.lock`, and cleanup failures.
@MainActor func loop4Mutations(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    MockHTTPBox.shared.set(39, body: page39)
    func signedIn(_ name: String, mirror: Bool = false, booked: [(Int, String)] = []) async throws -> (vm: ScheduleViewModel, store: SharedStateStore, kc: KeychainStore, mock: MobileMock, dir: URL, mirror: URL?) {
        let f = try ctx.freshVM(name, mirror: mirror)
        f.mock.bookings.value["tok_A"] = classesJSON(booked)
        await signIn(f.vm)
        await f.vm.load(forceRefresh: false) // club 39's timetable (row 501) is on disk for the live recheck
        try assertTrue(f.vm.memberSession?.token == "tok_A" && f.vm.bookings != nil && f.store.loadSnapshot(clubId: 39)?.days.values.joined().contains { $0.id == 501 } == true, "\(name): signed in with club 39 loaded")
        return f
    }
    func press(_ vm: ScheduleViewModel, cancel: Bool, token: String) async {
        await vm.handleClassAction(classId: 501, expectedCancel: cancel, expectedToken: token, expectedClubId: vm.preferences.clubId, title: "Open Reformer", startTime: openSlot.time,
                                   expectedDate: openSlot.date)
    }

    // A click whose drawn intent (Book or Cancel) or account no longer matches sends zero private requests.
    do {
        let f = try await signedIn("intent")
        let other = SharedStateStore(primaryDirectory: f.dir), stale = ScheduleViewModel.staleIntentMessage
        var before = f.mock.count
        try syncSeed(other, memberA, f.kc, [activeBooking(501, isoUTC(openSlot.start))])
        f.vm.syncFromDisk()
        await press(f.vm, cancel: false, token: "tok_A")
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale && f.vm.bookings?.bookedIds == [501], "Book drawn, cache reloaded as Booked: refused with 0 requests")
        try syncSeed(other, memberA, f.kc, [])
        await press(f.vm, cancel: true, token: "tok_A")
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale && f.vm.bookings?.bookedIds == [], "Cancel drawn, booking gone on disk only: the live recheck refuses it (0 requests)")
        try syncSeed(other, memberA, f.kc, [activeBooking(501, isoUTC(openSlot.start))])
        await press(f.vm, cancel: false, token: "tok_A")
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale && f.store.loadBookings(for: memberA)?.bookedIds == [501], "Book drawn, booked on disk only: the live recheck refuses it (0 requests)")
        before = f.mock.count
        _ = try other.commitLogin(memberB, keychain: f.kc)
        await press(f.vm, cancel: true, token: "tok_A")
        try assertTrue(f.mock.count == before && f.vm.memberSession?.token == "tok_B", "an account switched on disk refuses the old account's click and shows the new account (0 requests)")
        await press(f.vm, cancel: false, token: "tok_A")
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale, "a click drawn for the previous account is refused (0 requests)")
    }

    // A refresh started before acceptance never wins, whichever finishes last: disk, menu, and widget keep the booking.
    for postDelay in [0.0, 0.6] {
        let f = try await signedIn("accept-order-\(postDelay)", mirror: true)
        f.mock.classesDelays.value = [0.3, postDelay]
        drain(f.mock.classesArrived)
        let preAcceptance = Task { await f.vm.load(forceRefresh: true) }
        try assertTrue(await waitFor(f.mock.classesArrived), "pre-acceptance refresh is in flight")
        f.mock.bookings.value["tok_A"] = classesJSON([(501, isoUTC(openSlot.start))])
        try await click(f.vm, open501)
        await preAcceptance.value
        try assertTrue(f.vm.bookings?.bookedIds == [501] && f.store.loadBookings(for: memberA)?.bookedIds == [501] && SharedStateStore(primaryDirectory: f.mirror!).loadBookedIds() == [501],
                       "post-acceptance refresh wins on disk, menu, and widget (pre-acceptance finishes \(postDelay == 0 ? "last" : "first"))")
    }

    // During a delayed failed follow-up, another refresh is refused (the follow-up then clears the cache), and an
    // account switch is followed.
    for replaced in [false, true] {
        let f = try await signedIn("followup-\(replaced)")
        f.mock.classesStatus.value["tok_A"] = 503; f.mock.classesDelays.value = [0.3]
        drain(f.mock.classesArrived)
        let action = Task { try await click(f.vm, open501) }
        try assertTrue(await waitFor(f.mock.classesArrived), "the follow-up refresh is in flight")
        let other = SharedStateStore(primaryDirectory: f.dir)
        var refused = ""
        if replaced { _ = try other.commitLogin(memberB, keychain: f.kc) } else { refused = denial { try syncSeed(other, memberA, f.kc, [activeBooking(501, isoUTC(openSlot.start))]) } }
        try await action.value
        let banner = f.vm.bannerMessage ?? ""
        if replaced {
            try assertTrue(f.vm.memberSession?.token == "tok_B" && (try f.kc.readSession())?.token == "tok_B" && banner.contains(FollowUpCleanupOutcome.superseded.summary),
                           "a 503 follow-up after an account switch reports .superseded and shows the new account")
        } else {
            try assertTrue(refused == BookingClientError.staleRefresh.localizedDescription && f.vm.bookings == nil && f.store.loadBookings(for: memberA) == nil
                           && banner.contains(FollowUpCleanupOutcome.cleared.summary),
                           "a refresh during the mutation's follow-up is refused (.staleRefresh) and the failed follow-up clears the cache")
        }
    }

    // A lost reply (garbled body or dropped connection after the server may have accepted) leaves bookings unknown.
    for drop in [false, true] {
        let label = drop ? "transport drop" : "invalid response", dir = ctx.scratch("lost-reply-\(drop)"), kcL = ctx.keychain("lost-reply")
        let st = SharedStateStore(primaryDirectory: dir), calls = Locked(0)
        try loginSeed(st, memberA, kcL, [])
        try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [openSlot.date: [open501]], syncedAt: Date(), daySyncedAt: [openSlot.date: Date()]))
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            calls.mutate { $0 += 1 }
            if req.url.contains("book_class") {
                if drop { throw BookingClientError.transportError("Connection reset by peer.") }
                return (200, Data("<html>gateway</html>".utf8))
            }
            return (200, Data(classesJSON([(501, isoUTC(openSlot.start))]).utf8))
        }
        let pub = mockPublicClient(store: st)
        let first = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: st, keychain: kcL, client: pub, bookingClient: client) }
        let reopened = SharedStateStore(primaryDirectory: dir)
        let second = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: reopened, keychain: kcL, client: pub, bookingClient: client) }
        let reopenedVM = ScheduleViewModel(store: reopened, keychain: kcL, client: pub, bookingClient: client)
        try assertTrue(!first.isEmpty && second.contains("out of sync") && calls.value == 1 && reopened.loadBookings(for: memberA) == nil && !reopenedVM.canUseBookingActions,
                       "\(label): a reopened store and menu refuse the next mutation until Refresh (0 background calls)")
        _ = try await client.syncBookings(for: memberA, store: reopened, keychain: kcL)
        try assertTrue(reopened.loadBookings(for: memberA)?.bookedIds == [501] && calls.value == 2, "\(label): an explicit Refresh restores the cache")
    }

    // A sign-out that completes between beginMutation and the transport handoff: zero requests with the old token.
    do {
        let service = ctx.keychainService("handoff"), armed = Locked(false), reads = Locked(0)
        let kcH = KeychainStore(service: service, account: "verify", hooks: .init(getInteractionAllowed: {
            var n = 0
            if armed.value { reads.mutate { $0 += 1; n = $0 } }
            // Read 1 is beginMutation's session check; read 2 is the handoff gate: the item disappears in between. Read 3
            // is the failed-dispatch cleanup, which finds no session and touches nothing.
            if n == 2 { _ = try? runSubprocess("/usr/bin/security", args: ["delete-generic-password", "-s", service, "-a", "verify"]) }
            return (0, true)
        }))
        let st = SharedStateStore(primaryDirectory: ctx.scratch("handoff")), mock = MobileMock()
        try loginSeed(st, memberA, kcH, [])
        armed.value = true
        let refused = await denialAsync { _ = try await mock.client.mutateAndSync(classId: 501, isCancel: false, session: memberA, store: st, keychain: kcH) { _, _, _ in false } }
        armed.value = false
        try assertTrue(refused == BookingClientError.sessionSuperseded.localizedDescription && mock.count == 0 && reads.value == 2 && (try kcH.readSession()) == nil,
                       "sign-out between beginMutation and the transport handoff sends 0 requests with the old token")
    }

    // A Book queued behind another process's `.mutation.lock` is rechecked on live disk state once the lock frees.
    let farRow = ClassSession(id: 501, date: farSlot.date, startTime: farSlot.time, endTime: "23:59", durationMinutes: 45, title: "Open Reformer", trainer: "", clubName: "Canary Wharf")
    let changes: [(String, String, (SharedStateStore, KeychainStore) throws -> Void)] = [
        ("removed", "not found", { st, _ in try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: []], syncedAt: Date(), daySyncedAt: [todayIso: Date()])) }),
        ("moved past 48h", ScheduleViewModel.staleIntentMessage, { st, _ in try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [farSlot.date: [farRow]], syncedAt: Date(), daySyncedAt: [farSlot.date: Date()])) }),
        ("club switched by the CLI", ScheduleViewModel.staleIntentMessage, { st, _ in _ = try st.updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" } }),
        ("unentitled", "not found", { _, kc in try kc.saveSession(MemberSession(token: "tok_A", id: 7, name: "A", email: "a@example.com", homeClubId: 200, homeClubName: "Wood Wharf", expiresAt: "", clubs: [woodWharf])) }),
    ]
    for (label, reason, change) in changes {
        let f = try await signedIn("queued-\(label)")
        let holder = SharedStateStore(primaryDirectory: f.dir), held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lockTask = Task.detached { try await holder.withMutationLock(classId: 999) { held.signal(); _ = await waitFor(release, seconds: 4) } }
        try assertTrue(await waitFor(held), "another process holds .mutation.lock")
        let before = f.mock.count
        let queued = Task { try await click(f.vm, open501) }
        for _ in 0..<1000 where f.vm.busyClassId != 501 { await Task.yield() }
        try assertEqual(f.vm.busyClassId, 501, "\(label): the Book click is queued behind the lock")
        try change(SharedStateStore(primaryDirectory: f.dir), f.kc)
        release.signal()
        try await queued.value
        _ = try? await lockTask.value
        try assertTrue(f.mock.count == before && f.vm.bannerIsError && (f.vm.bannerMessage ?? "").contains(reason) && f.store.loadBookings(for: memberA) != nil,
                       "\(label): the live recheck under the lock refuses the queued Book (0 requests, cache still valid)")
    }

    // Keychain UI suppression fails right after the unreadable item was deleted, and local cleanup fails too.
    do {
        let service = ctx.keychainService("lost-cleanup"), calls = Locked(0)
        let failing = KeychainStore(service: service, account: "verify", hooks: .init(getInteractionAllowed: {
            var n = 0
            calls.mutate { $0 += 1; n = $0 }
            return n == 5 ? (-50, true) : (0, true) // call 3 guards SecItemAdd, right after the ACL-rejected item was deleted
        }))
        let dir = ctx.scratch("lost-cleanup"), mdir = ctx.scratch("lost-cleanup-mirror")
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        try loginSeed(st, canaryMember, ctx.keychain("lost-cleanup-seed"), bookingsA.bookings)
        try seedForeignKeychainItem(service: service, account: "verify")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mdir.path)
        let lost = Result { try st.commitLogin(memberB, keychain: failing) }.error
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mdir.path)
        guard case .previousSessionLost(-50, let cleanupError?)? = lost as? KeychainError else { throw AssertionFailure(description: "FAIL: expected previousSessionLost with cleanupError, got \(String(describing: lost))") }
        try assertTrue(!cleanupError.isEmpty && (lost?.localizedDescription ?? "").contains("Clearing local account files also failed"), "previousSessionLost reports the failed account-file cleanup")
    }

    // A primary bookings.json that cannot be deleted after a failed follow-up: host actions blocked, widget badges gone.
    do {
        let f = try await signedIn("pinned", mirror: true, booked: [(502, isoUTC(lateSlot.start))])
        let pinned = f.dir.appendingPathComponent("bookings.json")
        f.mock.classesStatus.value["tok_A"] = 503
        try fm.setAttributes([.immutable: true], ofItemAtPath: pinned.path)
        try await click(f.vm, open501)
        try fm.setAttributes([.immutable: false], ofItemAtPath: pinned.path)
        let before = f.mock.count
        let cli = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: f.store, keychain: f.kc, client: mockPublicClient(store: f.store), bookingClient: f.mock.client) }
        try assertTrue(f.vm.bookings == nil && (f.vm.bannerMessage ?? "").contains("Clearing cached bookings also failed") && fm.fileExists(atPath: pinned.path) && !f.vm.canUseBookingActions
                       && f.store.loadBookings(for: memberA) == nil && SharedStateStore(primaryDirectory: f.mirror!).loadBookedIds() == [] && cli.contains("out of sync") && f.mock.count == before,
                       "bookingsValid=false blocks host actions and drops widget badges even though bookings.json survived")
    }

    // A 403 that negates the auth phrase keeps the login; "Token expired" ends it.
    do {
        let f = try await signedIn("auth403")
        f.mock.classesStatus.value["tok_A"] = 403; f.mock.errorMessages.value["tok_A"] = "This is not an invalid token"
        await f.vm.load(forceRefresh: true)
        let kept = try f.vm.memberSession?.token == "tok_A" && (f.kc.readSession())?.token == "tok_A"
        f.mock.errorMessages.value["tok_A"] = "Token expired"
        await f.vm.load(forceRefresh: true)
        try assertTrue(kept && f.vm.memberSession == nil && (try f.kc.readSession()) == nil, "403 'not an invalid token' keeps the login; 403 'Token expired' signs out")
    }
}

/// Loop 4: strict account files, bounded locks, mirror aliasing, quiet reconciliation, preference warnings, snapshot
/// metadata, locked club alignment, booked-row visibility, uncached days, superseded discovery, and widget consistency.
@MainActor func loop4StateAndClubs(_ ctx: TestContext) async throws {
    let fm = ctx.fm

    // Corrupt account.json and sequence.json fail loudly and are never reset.
    do {
        let dir = ctx.scratch("corrupt"), kcC = ctx.keychain("corrupt")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["account.json", "sequence.json"] { try "{broken".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let st = SharedStateStore(primaryDirectory: dir)
        try assertTrue(!denial { _ = try st.commitLogin(memberA, keychain: kcC) }.isEmpty && (try kcC.readSession()) == nil, "commitLogin on a corrupt account.json fails before the Keychain is touched")
        try assertTrue(!denial { _ = try st.reserveSnapshotSequence() }.isEmpty, "a corrupt sequence.json fails the next request number")
        for name in ["account.json", "sequence.json"] {
            try assertEqual(try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), "{broken", "\(name) is never reset to 0")
        }
    }

    // A contended state lock times out cleanly; the menu reports it instead of hanging.
    do {
        let dir = ctx.scratch("lock-timeout")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let st = SharedStateStore(primaryDirectory: dir, lockTimeout: 0.2)
        let fd = Darwin.open(dir.appendingPathComponent(".preferences.lock").path, O_CREAT | O_RDWR, 0o600)
        try assertTrue(fd >= 0 && flock(fd, LOCK_EX) == 0, "test holds .preferences.lock")
        let began = Date()
        let denied = denial { _ = try st.updatePreferences { $0.period = .evening } }
        let vm = ScheduleViewModel(store: st, keychain: ctx.keychain("lock-timeout"), client: mockPublicClient(store: st), bookingClient: MobileMock().client)
        vm.selectPeriod(.evening)
        flock(fd, LOCK_UN); Darwin.close(fd)
        try assertTrue(denied == StoreError.lockTimedOut(".preferences.lock").localizedDescription && Date().timeIntervalSince(began) < 2 && vm.preferences.period == .all
                       && vm.bannerIsError && (vm.bannerMessage ?? "").contains("Another Tertia process"), "a contended lock times out via lockTimeout and the menu says so")
    }

    // A mirror that aliases the primary folder (same path or a symlink to it) is disabled.
    for symlinked in [false, true] {
        let dir = ctx.scratch("alias-\(symlinked)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var mirror = dir
        if symlinked { mirror = ctx.scratch("alias-link"); try fm.createSymbolicLink(at: mirror, withDestinationURL: dir) }
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mirror)
        try loginSeed(st, canaryMember, ctx.keychain("alias"), bookingsA.bookings)
        // A live mirror would overwrite bookings.json with the compact ID list, so the full record would not load.
        try assertEqual(st.loadBookings(for: canaryMember)?.bookedIds, [3064910], "\(symlinked ? "a symlinked" : "an identical") mirror directory is disabled")
    }

    // `.mutation.lock` is one file whatever the class IDs; invalid IDs fail before any file is created.
    do {
        let dir = ctx.scratch("mutation-lock"), st = SharedStateStore(primaryDirectory: dir)
        var invalid = 0
        for id in [0, -5, Int.min] { if (try? await st.withMutationLock(classId: id) { @Sendable in id }) == nil { invalid += 1 } }
        for id in 1...40 { _ = try await st.withMutationLock(classId: id) { @Sendable in id } }
        try assertTrue(invalid == 3 && (try fm.contentsOfDirectory(atPath: dir.path)).filter { $0.contains("lock") } == [".mutation.lock"], ".mutation.lock leaves exactly 1 lock file across many class IDs")
    }

    // Reconciliation of an aligned store writes nothing.
    do {
        let dir = ctx.scratch("quiet"), mdir = ctx.scratch("quiet-mirror"), kcQ = ctx.keychain("quiet")
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        try loginSeed(st, memberA, kcQ, [activeBooking(501, isoUTC(openSlot.start))])
        let files = [dir, mdir].flatMap { [$0.appendingPathComponent("account.json"), $0.appendingPathComponent("bookings.json")] }
        func stamps() throws -> [String] {
            try files.map { let a = try fm.attributesOfItem(atPath: $0.path); return "\(a[.systemFileNumber] ?? 0)/\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" }
        }
        let before = try stamps()
        try st.reconcileAccountMirror(for: memberA, keychain: kcQ)
        try assertEqual(try stamps(), before, "reconcileAccountMirror performs 0 writes on a healthy store")
    }

    // A failed widget-mirror preference write keeps the committed change in the menu and warns.
    do {
        let f = try ctx.freshVM("pref-mirror", mirror: true)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.mirror!.path)
        f.vm.selectPeriod(.evening)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.mirror!.path)
        try assertTrue(f.vm.preferences.period == .evening && f.store.loadPreferences().period == .evening && f.vm.bannerIsError && (f.vm.bannerMessage ?? "").contains("updating the widget copy failed"),
                       "a preference mirror failure keeps the primary update and shows a warning")
    }

    // A corrupt widget snapshot copy is repaired on a primary cache hit (no HTTP).
    do {
        let dir = ctx.scratch("corrupt-mirror"), mdir = ctx.scratch("corrupt-mirror-widget")
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        _ = try await mockPublicClient(store: host).fetchSchedule(clubId: 39, date: todayIso)
        try "{broken".write(to: mdir.appendingPathComponent("snapshot-39.json"), atomically: true, encoding: .utf8)
        let hits = MockHTTPBox.shared.count(39)
        _ = try await mockPublicClient(store: host).fetchSchedule(clubId: 39, date: todayIso)
        try assertTrue(MockHTTPBox.shared.count(39) == hits && SharedStateStore(primaryDirectory: mdir).loadSnapshot(clubId: 39)?.hasCachedDay(todayIso) == true, "a corrupt mirror snapshot is repaired on a primary cache hit")
    }

    // Club metadata follows request order, and a clock rollback never pins old metadata or a future syncedAt.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("rename"))
        let older = try st.reserveSnapshotSequence(), newer = try st.reserveSnapshotSequence()
        _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [], clubName: "Canary Wharf Renamed", clubShortCode: "CWR", fetchedDays: [:], fetchedRange: [todayIso], requestSeq: newer, syncedAt: Date())
        _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [:], fetchedRange: [todayIso], requestSeq: older, syncedAt: Date())
        try assertEqual(st.loadSnapshot(clubId: 39)?.clubName, "Canary Wharf Renamed", "an older response finishing last never restores the old club name")
        let future = Date().addingTimeInterval(3600), now = Date()
        try st.seedSnapshot(TimetableSnapshot(clubs: [], clubId: 52, clubName: "Soho Old", clubShortCode: "SO", days: [todayIso: []], syncedAt: future, daySyncedAt: [todayIso: future], dayRevision: [todayIso: .max], metaRevision: .max))
        let merged = try st.mergeAndSaveSnapshot(clubId: 52, clubs: [], clubName: "Soho", clubShortCode: "SOHO", fetchedDays: [todayIso: []], fetchedRange: [todayIso], requestSeq: try st.reserveSnapshotSequence(), syncedAt: now, now: now)
        let stored = st.loadSnapshot(clubId: 52)
        try assertTrue(merged.clubName == "Soho" && stored?.clubName == "Soho" && merged.syncedAt <= now.addingTimeInterval(2) && (stored?.syncedAt ?? .distantFuture) <= now.addingTimeInterval(2),
                       "after a clock rollback, club metadata and syncedAt follow the new response")
    }

    // Club alignment runs under the store lock: it keeps a newer valid CLI choice and moves an 18th club back to the 17.
    let zeta = Club(id: 250, name: "Zeta Extra", shortCode: "ZX")
    let member18 = MemberSession(token: "tok_18", id: 18, name: "E", email: "e@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf, zeta])
    for (cliClub, expected) in [(200, 200), (250, 39)] {
        let f = try ctx.freshVM("align-\(cliClub)", seed: { st, kcV, _, _ in
            try st.seedSnapshot(TimetableSnapshot(clubs: Club.defaultClubs + [zeta], clubId: 52, clubName: "Soho", clubShortCode: "SOHO", days: [:], syncedAt: Date()))
            try kcV.saveSession(member18)
        })
        let cli = SharedStateStore(primaryDirectory: f.dir)
        _ = try await TertiaCLI.applyWidgetClub(clubId: 250, store: cli, keychain: f.kc, client: mockPublicClient(store: cli))
        f.vm.syncFromDisk()
        let picked18th = f.vm.preferences.clubId == 250 && f.vm.availableClubs.contains(zeta)
        if cliClub != 250 { _ = try await TertiaCLI.applyWidgetClub(clubId: cliClub, store: cli, keychain: f.kc, client: mockPublicClient(store: cli)) }
        f.vm.signOut()
        try assertTrue(picked18th && f.vm.memberSession == nil && f.vm.preferences.clubId == expected && f.store.loadPreferences().clubId == expected
                       && f.vm.availableClubs.count == 17 && f.vm.availableClubs.contains { $0.id == expected },
                       cliClub == 250 ? "sign-out from the member-only 18th club realigns into the 17-club picker" : "sign-out keeps a newer valid CLI club choice")
    }

    // A booked row whose public start passed 16 minutes ago stays (BOOKED · CANCEL) until the booking's own start.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("booked-row"))
        let vm = ScheduleViewModel(store: st, keychain: ctx.keychain("booked-row"), client: mockPublicClient(store: st), bookingClient: MobileMock().client)
        let noon = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "12:00")!, memberStart = noon.addingTimeInterval(30 * 60)
        let row = ClassSession(id: 701, date: todayIso, startTime: "11:44", endTime: "12:30", durationMinutes: 46, title: "Booked Ride", trainer: "", clubName: "Canary Wharf")
        vm.snapshot = TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: [row]], syncedAt: noon, daySyncedAt: [todayIso: noon])
        vm.memberSession = memberA
        vm.bookings = BookingsSnapshot(ownerKey: memberA.ownerKey!, bookings: [activeBooking(701, isoUTC(memberStart))], syncedAt: noon)
        try assertTrue(LondonCalendar.filterSessions([row], period: .all, search: "", selectedDate: todayIso, now: noon).isEmpty && vm.filteredClasses(now: noon).map(\.id) == [701]
                       && vm.badge(for: row, now: noon).label == "BOOKED · CANCEL" && vm.filteredClasses(now: memberStart).isEmpty
                       && LondonCalendar.upcomingBoundaryDates(for: [row], now: noon, activeBookingStarts: vm.bookings!.activeBookingStarts).contains(memberStart),
                       "a booked row 16m past its public start shows BOOKED · CANCEL until the booking's own start, then leaves at that redraw")
    }

    // A CLI club switch while the menu shows day 9: the stale error clears, the day reads as not loaded, and it loads.
    do {
        let f = try ctx.freshVM("day9")
        let day9 = LondonCalendar.addDays(to: todayIso, days: 9)!
        f.vm.selectedDate = day9; f.vm.errorMessage = "stale error from club 39"
        MockHTTPBox.shared.set(200, body: timetableHTML([Fx(id: 601, slot: openSlot, title: "Wood Wharf Ride", club: "Wood Wharf")]))
        let cli = SharedStateStore(primaryDirectory: f.dir)
        _ = try await TertiaCLI.applyWidgetClub(clubId: 200, store: cli, keychain: f.kc, client: mockPublicClient(store: cli))
        let hits = MockHTTPBox.shared.count(200)
        f.vm.syncFromDisk()
        let notLoaded = f.vm.preferences.clubId == 200 && f.vm.errorMessage == nil && !f.vm.isShownDayCached() && f.vm.filteredClasses().isEmpty
        for _ in 0..<300 where !(f.vm.isShownDayCached() && !f.vm.isLoading) { try await Task.sleep(nanoseconds: 10_000_000) }
        try assertTrue(notLoaded && f.vm.isShownDayCached() && f.vm.snapshot?.clubId == 200 && MockHTTPBox.shared.count(200) == hits + 1,
                       "a CLI club switch on day 9 clears the stale error, shows the not-loaded copy, and loads that day")
    }

    // A club discovery 503 superseded by a newer load is not reported.
    do {
        let f = try ctx.freshVM("discovery")
        await signIn(f.vm, "none@example.com")
        let probe = Club.defaultClubs[0].id
        MockHTTPBox.shared.set(probe, status: 503, body: "busy")
        await f.vm.load(forceRefresh: true)
        let reported = (f.vm.bannerMessage ?? "").contains("Could not refresh the public club list")
        f.vm.bannerMessage = nil
        MockHTTPBox.shared.set(probe, status: 503, body: "busy", delay: 0.3)
        let entered = DispatchSemaphore(value: 0)
        MockHTTPBox.shared.onEntry(probe) { entered.signal() }
        let discovery = Task { await f.vm.load(forceRefresh: true) }
        try assertTrue(await waitFor(entered), "club discovery is in flight")
        await f.vm.load(forceRefresh: false)
        await discovery.value
        MockHTTPBox.shared.set(probe, body: timetableHTML([], clubs: [Club.defaultClubs[0]]))
        try assertTrue(reported && f.vm.bannerMessage == nil && f.vm.errorMessage == ScheduleViewModel.noClubsMessage, "a superseded club-discovery 503 is ignored (a current one is reported)")
    }

    // The widget reads preferences, snapshot, and booked IDs together after its public fetch.
    do {
        let dir = ctx.scratch("widget-await"), kcW = ctx.keychain("widget-await"), widgetStore = SharedStateStore(primaryDirectory: dir)
        try loginSeed(widgetStore, memberA, kcW, [activeBooking(501, isoUTC(openSlot.start))])
        let row601 = ClassSession(id: 601, date: todayIso, startTime: "23:59", endTime: "23:59", durationMinutes: 0, title: "Wood Wharf Ride", trainer: "", clubName: "Wood Wharf")
        try widgetStore.seedSnapshot(TimetableSnapshot(clubs: [woodWharf], clubId: 200, clubName: "Wood Wharf", clubShortCode: "WW", days: [todayIso: [row601]], syncedAt: Date(), daySyncedAt: [todayIso: Date()]))
        MockHTTPBox.shared.set(39, body: page39, delay: 0.3)
        let entered = DispatchSemaphore(value: 0)
        MockHTTPBox.shared.onEntry(39) { entered.signal() }
        let pending = Task { await refreshWidgetState(store: widgetStore, client: mockPublicClient(store: widgetStore)) }
        try assertTrue(await waitFor(entered), "the widget's public fetch is in flight")
        let other = SharedStateStore(primaryDirectory: dir)
        _ = try other.updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" }
        // B's booking names the Wood Wharf row it badges (its row token binds the club and London date).
        try loginSeed(other, memberB, kcW, [MemberBooking(id: 601, title: "Wood Wharf Ride", startDate: isoUTC(LondonCalendar.startDate(of: row601)!), clubName: "Wood Wharf",
                                                          trainerName: "", eventAction: "cancel")])
        let state = await pending.value
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(state.preferences.clubId == 200 && state.snapshot?.clubId == 200 && state.bookedIds == [601],
                       "after a club and account switch during the widget fetch, its entry uses one consistent state")
    }
}

/// Connects a client socket to 127.0.0.1:`port`; -1 on failure.
func loopbackConnect(_ port: Int) -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = UInt16(port).bigEndian
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if ok != 0 { Darwin.close(fd); return -1 }
    return fd
}

/// Loop 5 transport: the bounded loopback server, curl stdin backpressure and early close, and a full locally
/// negotiated HTTPS exchange (TLS 1.3, ALPN h2) checked against the Android 6.7.4 reference fixture.
@MainActor func loop5Transport(_ ctx: TestContext) async throws {
    let fm = ctx.fm
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    // The shared loopback server ends by its deadline when no client connects, and when a client stops mid-record.
    do {
        let began = Date()
        let (_, idle) = try acceptAndServeBounded(seconds: 0.3) { _ in true }
        let idleResult = await idle.value, idleTime = Date().timeIntervalSince(began)
        let partialStart = Date()
        let (port, partial) = try acceptAndServeBounded(seconds: 0.3) { conn -> Int in
            var bytes = [UInt8]()
            while bytes.count < 5 || bytes.count < 5 + (Int(bytes[3]) << 8 | Int(bytes[4])) { guard let chunk = conn.read() else { break }; bytes += chunk }
            return bytes.count
        }
        let client = loopbackConnect(port)
        let header: [UInt8] = [0x16, 0x03, 0x01] // three bytes of a TLS record header, then silence with the socket open
        _ = header.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
        let partialResult = await partial.value, partialTime = Date().timeIntervalSince(partialStart)
        Darwin.close(client)
        try assertTrue(idleResult == nil && idleTime < 0.5, "a client that never connects ends the bounded accept by its deadline (\(String(format: "%.2f", idleTime))s)")
        try assertTrue(client >= 0 && partialResult == 3 && partialTime < 0.5, "an incomplete record ends the bounded read by its deadline (\(String(format: "%.2f", partialTime))s)")
    }

    // curl stdin: a 256 KB body against a child that never reads times out; a child that closes stdin fails fast.
    do {
        let big = MobileRequest(method: "POST", url: "http://127.0.0.1:9/", headers: [], body: "{\"pad\":\"" + String(repeating: "a", count: 256 * 1024) + "\"}")
        let began = Date()
        let stalled = denial { _ = try MobileBookingClient.runCurlSync(big, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "exec /bin/sleep 10"], timeoutSeconds: 0.4)) }
        let stalledTime = Date().timeIntervalSince(began)
        try assertTrue(stalled == "Network request timed out." && stalledTime < 1.8, "a 256 KB config against a child that never reads stdin times out (\(String(format: "%.2f", stalledTime))s)")
        let closeStart = Date()
        var closedError: BookingClientError?
        do { _ = try MobileBookingClient.runCurlSync(big, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "exec 0<&-; printf 'err\\n' >&2; exit 7"], timeoutSeconds: 5)) }
        catch { closedError = error as? BookingClientError }
        let closeTime = Date().timeIntervalSince(closeStart)
        guard case .transportError(let message)? = closedError else { throw AssertionFailure(description: "FAIL: early stdin close should be a transport error, got \(String(describing: closedError))") }
        try assertTrue(message != "Network request timed out." && closeTime < 1.5, "a child that closes stdin early fails with a broken-pipe or exit error, not the timeout (\(message), \(String(format: "%.2f", closeTime))s)")
    }

    // A full HTTPS exchange: /usr/bin/curl negotiates TLS 1.3 and ALPN h2 with a local server (ephemeral self-signed
    // 127.0.0.1 certificate), which answers login and an authenticated bookings request over HTTP/2.
    let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Scripts/Fixtures/android-6.7.4-wire-profile.json"))) as? [String: Any] ?? [:]
    let fixtureCiphers = (fixture["tlsCiphers"] as? [[String: String]] ?? []).compactMap { $0["name"] }
    try assertTrue(fixtureCiphers.joined(separator: ":") == MobileBookingClient.tlsCiphers && fixture["userAgent"] as? String == MobileBookingClient.userAgent
                   && fixture["appVersion"] as? String == MobileBookingClient.appVersion && fixture["baseURL"] as? String == MobileBookingClient.defaultBaseURL,
                   "the client constants match Scripts/Fixtures/android-6.7.4-wire-profile.json")
    let python = try testPython(root: root)
    let tlsDir = ctx.scratch("tls13")
    try fm.createDirectory(at: tlsDir, withIntermediateDirectories: true)
    let cert = tlsDir.appendingPathComponent("cert.pem").path, key = tlsDir.appendingPathComponent("key.pem").path, server = tlsDir.appendingPathComponent("h2server.py").path
    let made = try runSubprocess("/usr/bin/openssl", args: ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=127.0.0.1",
                                                          "-addext", "subjectAltName=IP:127.0.0.1", "-addext", "basicConstraints=critical,CA:TRUE"], timeoutSeconds: 10)
    try assertTrue(made.status == 0 && !made.timedOut, "openssl made an ephemeral 127.0.0.1 certificate")
    // The accepted TCP socket arrives as stdin; the server negotiates TLS, reads one HTTP/2 request, answers it, and
    // prints what it negotiated and received.
    try """
    import json, signal, socket, ssl, sys
    signal.alarm(8)
    cert, key, body = sys.argv[1], sys.argv[2], bytes.fromhex(sys.argv[3])
    raw = socket.socket(fileno=0)
    raw.settimeout(5)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.set_alpn_protocols(["h2"])
    ctx.load_cert_chain(cert, key)
    tls = ctx.wrap_socket(raw, server_side=True)
    buf = b""
    def need(n):
        global buf
        while len(buf) < n:
            chunk = tls.recv(65536)
            if not chunk:
                raise SystemExit("client closed early")
            buf += chunk
    def frame(kind, flags, stream, payload):
        return len(payload).to_bytes(3, "big") + bytes([kind, flags]) + stream.to_bytes(4, "big") + payload
    need(24)
    preface, buf = buf[:24], buf[24:]
    tls.sendall(frame(4, 0, 0, b""))
    block, data, stream = b"", b"", 1
    while True:
        need(9)
        length, kind, flags = int.from_bytes(buf[:3], "big"), buf[3], buf[4]
        stream_id = int.from_bytes(buf[5:9], "big") & 0x7FFFFFFF
        need(9 + length)
        payload, buf = buf[9:9 + length], buf[9 + length:]
        if kind == 4 and not flags & 1:
            tls.sendall(frame(4, 1, 0, b""))
        if kind in (0, 1) and flags & 8:
            payload = payload[1:len(payload) - payload[0]]
        if kind == 1 and flags & 0x20:
            payload = payload[5:]
        if kind in (1, 9):
            block += payload; stream = stream_id
        if kind == 0:
            data += payload
        if kind in (0, 1) and flags & 1:
            break
    tls.sendall(frame(1, 4, stream, b"\\x88") + frame(0, 1, stream, body))
    print(json.dumps({"alpn": tls.selected_alpn_protocol(), "version": tls.version(), "cipher": tls.cipher()[0],
                      "preface": preface.hex(), "block": block.hex(), "data": data.hex()}), flush=True)
    try:
        tls.settimeout(2)
        while tls.recv(65536):
            pass
    except Exception:
        pass
    """.write(toFile: server, atomically: true, encoding: .utf8)

    struct Exchange { let alpn, version, cipher: String; let preface: [UInt8]; let fields: [(String, String)]; let body: String }
    func hexBytes(_ hex: String) -> [UInt8] { stride(from: 0, to: hex.count - 1, by: 2).compactMap { UInt8(String(Array(hex)[$0...$0 + 1]), radix: 16) } }
    /// Serves one TLS connection through the shared bounded server (Python does the TLS) while `request` runs.
    /// The parent's `CURL_SSL_BACKEND` is `backend` (unset for `nil`); production code alone pins the child's backend.
    func exchange(responding body: String, parentBackend backend: String?, _ request: @escaping @Sendable (MobileBookingClient) async throws -> Void) async throws -> Exchange {
        let bodyHex = Data(body.utf8).map { String(format: "%02x", $0) }.joined()
        let (port, served) = try acceptAndServeBounded(seconds: 9) { conn in
            try? runSubprocess(python, args: ["-I", server, cert, key, bodyHex], stdin: FileHandle(fileDescriptor: conn.fd, closeOnDealloc: false), timeoutSeconds: 9)
        }
        let client = MobileBookingClient(baseURL: "https://127.0.0.1:\(port)", transport: MobileBookingClient.makeCurlTransport(
            hooks: .init(arguments: ["--disable", "--cacert", cert, "--config", "-"], timeoutSeconds: 9)))
        if let backend { setenv("CURL_SSL_BACKEND", backend, 1) } else { unsetenv("CURL_SSL_BACKEND") }
        let failure = await denialAsync { try await request(client) }
        unsetenv("CURL_SSL_BACKEND")
        guard let run = await served.value ?? nil, run.status == 0 && !run.timedOut,
              let line = run.stdout.split(separator: "\n").last, let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] else {
            throw AssertionFailure(description: "FAIL: the local TLS 1.3 server did not complete (client: \(failure))")
        }
        try assertEqual(failure, "", "the request completed its encrypted round-trip")
        return Exchange(alpn: obj["alpn"] ?? "", version: obj["version"] ?? "", cipher: obj["cipher"] ?? "", preface: hexBytes(obj["preface"] ?? ""),
                        fields: try hpackDecode(hexBytes(obj["block"] ?? "")), body: String(decoding: hexBytes(obj["data"] ?? ""), as: UTF8.self))
    }
    let session = Locked<MemberSession?>(nil), booked = Locked<[MemberBooking]>([])
    let login = try await exchange(responding: loginJSON(token: "syn_tok_ref", id: 7, email: "a@b.com"), parentBackend: nil) { client in
        session.value = try await client.login(email: "a@b.com", password: "p@ss")
    }
    let fetch = try await exchange(responding: classesJSON([(501, "2026-11-22T10:00:00Z")]), parentBackend: "secure-transport") { client in
        booked.value = try await client.fetchBookings(token: "syn_tok_ref")
    }
    let pseudo = fixture["h2PseudoHeadersOrder"] as? [String] ?? []
    func check(_ x: Exchange, method: String, path: String, order: String, extra: [String: String], body: String, label: String) throws {
        try assertTrue(x.alpn == "h2" && x.version == "TLSv1.3" && fixtureCiphers.contains(x.cipher), "\(label): negotiated ALPN h2, TLS 1.3, and a reference cipher (\(x.alpn), \(x.version), \(x.cipher))")
        try assertEqual(x.preface, Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8), "\(label): HTTP/2 client preface")
        try assertEqual(x.fields.prefix(pseudo.count).map(\.0), pseudo, "\(label): pseudo-headers in the fixture order")
        let pseudoValues = Dictionary(x.fields.prefix(pseudo.count).map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
        try assertTrue(pseudoValues[":method"] == method && pseudoValues[":scheme"] == "https" && pseudoValues[":path"] == path, "\(label): :method, :scheme, :path")
        let headers = Array(x.fields.dropFirst(pseudo.count))
        let values = ["user-agent": fixture["userAgent"] as? String ?? "", "accept-encoding": "gzip", "x-app-platform": fixture["platform"] as? String ?? "",
                      "x-app-version": fixture["appVersion"] as? String ?? ""].merging(extra) { $1 }
        try assertEqual(headers.map(\.0), (fixture[order] as? [String] ?? []).map { $0.lowercased() }, "\(label): header order matches the fixture's \(order)")
        try assertTrue(headers.allSatisfy { field in values[field.0].map { $0 == field.1 } ?? true } && !headers.contains { $0.0 == "accept" }, "\(label): header values match the fixture and no accept header is sent")
        try assertEqual(x.body, body, "\(label): exact JSON body")
    }
    let loginBody = "{\"email\":\"a@b.com\",\"password\":\"p@ss\"}"
    try check(login, method: "POST", path: "/api/v2/member/auth/login?api-version=2.0", order: "loginHeadersOrder",
              extra: ["content-type": "application/json", "content-length": "\(loginBody.utf8.count)"], body: loginBody, label: "TLS 1.3 login (parent CURL_SSL_BACKEND unset)")
    try check(fetch, method: "GET", path: "/api/v2/member/classes?api-version=2.0&Limits.Count=100&Range=future&Cancelled=false&ExcludeWaitingOnly=false",
              order: "authenticatedGetHeadersOrder", extra: ["x-fisikal-token": "syn_tok_ref"], body: "", label: "TLS 1.3 bookings (parent CURL_SSL_BACKEND=secure-transport)")
    try assertTrue(session.value?.token == "syn_tok_ref" && booked.value.map(\.id) == [501], "login and fetchBookings decoded the HTTP/2 responses of the encrypted exchange")
}

/// Loop 5: mutation ordering, handoff serialization, mirror warnings, consistent widget reads, monotonic deadlines,
/// Keychain warnings, the single appearance load, booking duplicates, midnight filtering, MCP and parser edges, and
/// the preview clock.
@MainActor func loop5State(_ ctx: TestContext) async throws {
    let fm = ctx.fm, root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func revision(_ dir: URL) -> Int { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("account.json")))) as? [String: Any])?["revision"] as? Int ?? -1 }
    func seed501(_ st: SharedStateStore) throws {
        try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [openSlot.date: [open501]], syncedAt: Date(), daySyncedAt: [openSlot.date: Date()]))
    }
    func signedInVM(_ name: String, mirror: Bool = false, onChange: (@Sendable () -> Void)? = nil) async throws -> (vm: ScheduleViewModel, store: SharedStateStore, kc: KeychainStore, mock: MobileMock, dir: URL, mirror: URL?) {
        let f = try ctx.freshVM(name, mirror: mirror, onChange: onChange)
        await signIn(f.vm)
        await f.vm.load(forceRefresh: false)
        try assertTrue(f.vm.memberSession?.token == "tok_A" && f.vm.canUseBookingActions, "\(name): signed in with club 39 loaded")
        return f
    }
    MockHTTPBox.shared.set(39, body: page39)
    let accepted = Data("{\"statusCode\":\"accepted\"}".utf8)

    // A refresh started while a mutation awaits its reply is refused; after the lost reply a reopened store refuses the
    // retry until an explicit Refresh succeeds.
    do {
        let dir = ctx.scratch("l5-inflight"), kcI = ctx.keychain("l5-inflight"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcI, [])
        try seed501(st)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), urls = Locked<[String]>([])
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            urls.mutate { $0.append(req.url) }
            if req.url.contains("book_class") {
                entered.signal(); _ = await waitFor(release, seconds: 4)
                throw BookingClientError.transportError("Connection reset by peer.")
            }
            return (200, Data(classesJSON([(501, isoUTC(openSlot.start))]).utf8))
        }
        let pub = mockPublicClient(store: st)
        let mutation = Task { await denialAsync { _ = try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: st, keychain: kcI, client: pub, bookingClient: client) } }
        try assertTrue(await waitFor(entered), "the Book request is awaiting its reply")
        let refused = await denialAsync { _ = try await client.syncBookings(for: memberA, store: SharedStateStore(primaryDirectory: dir), keychain: kcI) }
        let fetchesDuring = urls.value.filter { $0.contains("/member/classes?") }.count
        release.signal()
        let lost = await mutation.value
        let reopened = SharedStateStore(primaryDirectory: dir)
        let retry = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: reopened, keychain: kcI, client: pub, bookingClient: client) }
        let books = urls.value.filter { $0.contains("book_class") }.count
        _ = try await client.syncBookings(for: memberA, store: reopened, keychain: kcI)
        try assertTrue(refused == BookingClientError.staleRefresh.localizedDescription && fetchesDuring == 0 && lost.contains("Connection reset") && retry.contains("out of sync") && books == 1
                       && reopened.loadBookings(for: memberA)?.bookedIds == [501],
                       "a refresh during an in-flight mutation is refused (0 fetches); after the lost reply only an explicit Refresh re-enables actions")
    }

    // Account A's book is in flight, B signs in, A's acceptance arrives late: B's revision and refresh stay intact.
    do {
        let dir = ctx.scratch("l5-late-accept"), kcL = ctx.keychain("l5-late-accept"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcL, [])
        try seed501(st)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), seen = Locked<[String]>([])
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            let token = req.headers.first { $0.name == "x-fisikal-token" }?.value ?? ""
            seen.mutate { $0.append((req.url.contains("book_class") ? "book:" : "classes:") + token) }
            if req.url.contains("book_class") { entered.signal(); _ = await waitFor(release, seconds: 4); return (200, accepted) }
            return (200, Data(classesJSON(token == "tok_B" ? [(601, isoUTC(openSlot.start))] : [(501, isoUTC(openSlot.start))]).utf8))
        }
        let mutation = Task { try? await client.mutateAndSync(classId: 501, isCancel: false, session: memberA, store: st, keychain: kcL) { _, _, _ in false } }
        try assertTrue(await waitFor(entered), "A's Book request is in flight")
        let other = SharedStateStore(primaryDirectory: dir)
        _ = try other.commitLogin(memberB, keychain: kcL)
        let afterLogin = revision(dir)
        let early = await denialAsync { _ = try await client.syncBookings(for: memberB, store: other, keychain: kcL) }
        release.signal()
        let outcome = await mutation.value
        let afterAcceptance = revision(dir)
        let synced = try await client.syncBookings(for: memberB, store: other, keychain: kcL)
        guard case .acceptedRefreshFailed(let error, followUp: .cacheCleanup(let cleanup))? = outcome else { throw AssertionFailure(description: "FAIL: A's late acceptance should report a refused follow-up") }
        try assertTrue((error as? BookingClientError) == .sessionSuperseded && cleanup == .superseded && afterAcceptance == afterLogin
                       && early == BookingClientError.staleRefresh.localizedDescription && synced.snapshot.bookedIds == [601] && other.loadBookings(for: memberB)?.bookedIds == [601]
                       && !seen.value.contains("classes:tok_A"),
                       "A's late acceptance leaves B's revision untouched and sends no A follow-up; B's refresh then commits")
    }

    // The transport handoff and sign-out serialize under .account.lock: no handoff after a completed sign-out.
    do {
        let dir = ctx.scratch("l5-handoff"), kcH = ctx.keychain("l5-handoff"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcH, [])
        let inHandoff = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), handoffEnd = Locked<TimeInterval>(0), handoffs = Locked(0)
        let paused = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in
                inHandoff.signal(); _ = release.wait(timeout: .now() + 3)
                handoffs.mutate { $0 += 1 }; handoffEnd.value = ProcessInfo.processInfo.systemUptime
            }
            return (200, Data(classesJSON([]).utf8))
        }
        let sync = Task { await denialAsync { _ = try await paused.syncBookings(for: memberA, store: st, keychain: kcH) } }
        try assertTrue(await waitFor(inHandoff), "the handoff is running under the account lock")
        let signOut = Task.detached { () -> (Bool, TimeInterval) in
            let cleared = (try? SharedStateStore(primaryDirectory: dir).clearSession(keychain: kcH))?.didClear ?? false
            return (cleared, ProcessInfo.processInfo.systemUptime)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        release.signal()
        let (cleared, signedOutAt) = await signOut.value
        let firstResult = await sync.value
        // The reply then commits before the sign-out takes the lock, or is discarded after it; either way it ends signed out.
        try assertTrue(cleared && handoffs.value == 1 && signedOutAt > handoffEnd.value && ["", BookingClientError.sessionSuperseded.localizedDescription].contains(firstResult)
                       && st.loadBookings(for: memberA) == nil && (try kcH.readSession()) == nil,
                       "a sign-out during the handoff waits for it to finish, and the store ends signed out")
        try loginSeed(st, memberA, kcH, [])
        let atTransport = DispatchSemaphore(value: 0), go = DispatchSemaphore(value: 0), ran = Locked(false)
        let late = MobileBookingClient { req in
            atTransport.signal(); _ = await waitFor(go, seconds: 3)
            try MobileBookingClient.performHandoff(req) { _ in ran.value = true }
            return (200, Data(classesJSON([]).utf8))
        }
        let lateSync = Task { await denialAsync { _ = try await late.syncBookings(for: memberA, store: st, keychain: kcH) } }
        try assertTrue(await waitFor(atTransport), "the request is about to hand off")
        let clearedFirst = try st.clearSession(keychain: kcH).didClear
        go.signal()
        let lateResult = await lateSync.value
        try assertTrue(clearedFirst && !ran.value && lateResult == BookingClientError.sessionSuperseded.localizedDescription,
                       "after a completed sign-out the handoff gate refuses the credential (0 handoffs)")
    }

    // A failed private mirror write during a refresh keeps the primary bookings and revision coherent.
    do {
        let dir = ctx.scratch("l5-mirror-sync"), mdir = ctx.scratch("l5-mirror-sync-widget"), kcM = ctx.keychain("l5-mirror-sync")
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), mock = MobileMock()
        try loginSeed(st, memberA, kcM, [activeBooking(501, isoUTC(openSlot.start))])
        mock.bookings.value["tok_A"] = classesJSON([(502, isoUTC(lateSlot.start))])
        let overlapping = try st.beginBookingsSync(for: memberA, keychain: kcM)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mdir.path)
        let synced = try await mock.client.syncBookings(for: memberA, store: SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), keychain: kcM)
        let overtaken = try st.commitSyncedBookings([activeBooking(999, "")], for: memberA, started: overlapping, keychain: kcM)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mdir.path)
        let marker = (try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("account.json")))) as? [String: Any] ?? [:]
        try assertTrue(synced.mirrorError != nil && synced.snapshot.bookedIds == [502] && overtaken.snapshot.bookedIds == [502] && overtaken.mirrorError == nil
                       && SharedStateStore(primaryDirectory: dir).loadBookings(for: memberA)?.bookedIds == [502] && marker["revision"] as? Int == Int(overlapping.startedAtRevision) + 1 && marker["bookingsValid"] as? Bool == true,
                       "a failed widget mirror write is a separate warning; the primary bookings and revision stay coherent for a second store and an overlapping refresh")
    }

    // A lost reply disables an already open menu at once, both for its own click and for a CLI mutation (0 extra calls).
    do {
        let changes = Locked(0)
        let f = try await signedInVM("l5-open-lost", onChange: { changes.mutate { $0 += 1 } })
        f.mock.actionStatus.value = (200, "<html>gateway</html>")
        let before = f.mock.count, notified = changes.value
        try await click(f.vm, open501)
        try assertTrue(f.vm.bookings == nil && !f.vm.canUseBookingActions && !f.vm.cardInputs(for: open501).canAct && f.mock.count == before + 1 && changes.value > notified,
                       "a lost reply in the open menu disables BOOK and CANCEL immediately and notifies, with 0 extra private calls")
        let g = try await signedInVM("l5-cli-lost")
        g.mock.actionStatus.value = (200, "<html>gateway</html>")
        let cliStore = SharedStateStore(primaryDirectory: g.dir), cliNotified = Locked(false), cliBefore = g.mock.count
        let failed = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 501, isCancel: false, late: false, store: cliStore, keychain: g.kc, client: mockPublicClient(store: cliStore),
                                                                                bookingClient: g.mock.client, onStateChanged: { cliNotified.value = true }) }
        let shownBefore = g.vm.canUseBookingActions
        if cliNotified.value { g.vm.syncFromDisk() } // what the distributed notification delivers
        try assertTrue(!failed.isEmpty && cliNotified.value && shownBefore && !g.vm.canUseBookingActions && g.mock.count == cliBefore + 1,
                       "a CLI lost reply notifies, and the open menu disables its buttons on that notification with 0 extra private calls")
    }

    // CLI logout and a 401 expiry realign a member-only club (250) to Canary Wharf in both preference files before
    // notifying, and keep Soho (52), one of the 17 public clubs.
    let zeta = Club(id: 250, name: "Zeta Extra", shortCode: "ZX")
    let memberZ = MemberSession(token: "tok_Z", id: 25, name: "Z", email: "z@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, zeta])
    for (club, expected) in [(250, 39), (52, 52)] {
        for path in ["logout", "401"] {
            let dir = ctx.scratch("l5-realign"), mdir = ctx.scratch("l5-realign-widget"), kcR = ctx.keychain("l5-realign")
            let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), mock = MobileMock()
            try st.seedSnapshot(TimetableSnapshot(clubs: Club.defaultClubs + [zeta], clubId: 52, clubName: "Soho", clubShortCode: "SOHO", days: [:], syncedAt: Date()))
            _ = try st.commitLogin(memberZ, keychain: kcR)
            _ = try st.updatePreferences { $0.clubId = club; $0.clubName = club == 250 ? "Zeta Extra" : "Soho"; $0.clubShortCode = club == 250 ? "ZX" : "SOHO" }
            let atNotify = Locked<[Int]>([])
            let notify: @Sendable () -> Void = { atNotify.value = [SharedStateStore(primaryDirectory: dir).loadPreferences().clubId, SharedStateStore(primaryDirectory: mdir).loadPreferences().clubId] }
            if path == "logout" {
                _ = try await captureOutput { await TertiaCLI.run(args: ["logout"], store: st, keychain: kcR, client: mockPublicClient(store: st), bookingClient: mock.client, onStateChanged: notify) }
            } else {
                mock.classesStatus.value["tok_Z"] = 401
                _ = await denialAsync { _ = try await TertiaCLI.memberBookings(refresh: true, store: st, keychain: kcR, bookingClient: mock.client, onStateChanged: notify) }
            }
            try assertTrue(atNotify.value == [expected, expected] && (try kcR.readSession()) == nil, "CLI \(path) with club \(club) selected: primary and widget preferences hold \(expected) before notifying")
        }
    }

    // A 403 "Invalid tokenization" keeps the login; "Invalid token" ends it.
    do {
        let f = try await signedInVM("l5-403")
        f.mock.classesStatus.value["tok_A"] = 403; f.mock.errorMessages.value["tok_A"] = "Invalid tokenization"
        await f.vm.load(forceRefresh: true)
        let kept = try f.vm.memberSession?.token == "tok_A" && (f.kc.readSession())?.token == "tok_A"
        f.mock.errorMessages.value["tok_A"] = "Invalid token"
        await f.vm.load(forceRefresh: true)
        try assertTrue(kept && f.vm.memberSession == nil && (try f.kc.readSession()) == nil, "403 'Invalid tokenization' keeps the login; 403 'Invalid token' signs out")
    }

    // A club and account switch between the widget's two reads never pairs the old club with the new account's badges;
    // a locking writer waits until the read is done.
    do {
        let dir = ctx.scratch("l5-widget-read"), bdir = ctx.scratch("l5-widget-read-b"), kcA = ctx.keychain("l5-widget-a"), kcB = ctx.keychain("l5-widget-b")
        let stateB = SharedStateStore(primaryDirectory: bdir)
        // Each badge needs its booked row on London today in the shown club (row tokens bind ID, club, and date).
        let lateToday = isoUTC(LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "23:59")!)
        let rowsByClub = [39: [row(501, todayIso, "23:59")], 200: [ClassSession(id: 601, date: todayIso, startTime: "23:59", endTime: "23:59", durationMinutes: 0, title: "Row", trainer: "", clubName: "Wood Wharf")]]
        try loginSeed(stateB, memberB, kcB, [MemberBooking(id: 601, title: "Row", startDate: lateToday, clubName: "Wood Wharf", trainerName: "", eventAction: "cancel")])
        _ = try stateB.updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" }
        let filesB = try ["preferences.json", "account.json", "bookings.json"].map { ($0, try Data(contentsOf: bdir.appendingPathComponent($0))) }
        let rawSwitch = Locked(false), block = Locked(false), inHook = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let st = SharedStateStore(primaryDirectory: dir, betweenWidgetReads: {
            if rawSwitch.value { rawSwitch.value = false; for (name, data) in filesB { try? data.write(to: dir.appendingPathComponent(name)) } } // a writer that takes no lock
            if block.value { block.value = false; inHook.signal(); _ = resume.wait(timeout: .now() + 3) }
        })
        try loginSeed(st, memberA, kcA, [activeBooking(501, lateToday)])
        for (club, name) in [(39, "Canary Wharf"), (200, "Wood Wharf")] {
            try st.seedSnapshot(TimetableSnapshot(clubs: [canary, woodWharf], clubId: club, clubName: name, clubShortCode: "", days: [todayIso: rowsByClub[club]!], syncedAt: Date()))
        }
        block.value = true
        let reader = Task.detached { st.readConsistentWidgetState() }
        try assertTrue(await waitFor(inHook), "the widget read is between its two reads")
        let writer = Task.detached { () -> TimeInterval in
            _ = try? SharedStateStore(primaryDirectory: dir).updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" }
            return ProcessInfo.processInfo.systemUptime
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let releasedAt = ProcessInfo.processInfo.systemUptime
        resume.signal()
        let locked = await reader.value, wroteAt = await writer.value
        _ = try st.updatePreferences { $0.clubId = 39; $0.clubName = "Canary Wharf"; $0.clubShortCode = "CANARY" }
        rawSwitch.value = true
        let raced = st.readConsistentWidgetState(), after = st.readConsistentWidgetState()
        try assertTrue(locked.preferences.clubId == 39 && locked.snapshot?.clubId == 39 && locked.bookedIds == [501] && wroteAt >= releasedAt,
                       "a locking club switch waits until the widget read finishes (old club, old badges)")
        try assertTrue(raced.bookedIds.isEmpty && raced.snapshot?.clubId == raced.preferences.clubId && after.preferences.clubId == 200 && after.snapshot?.clubId == 200 && after.bookedIds == [601],
                       "a switch between the two reads shows no badges, never the old club with the new account's badges")
    }

    // The host's mirror repair keeps a newer widget-side club rename.
    do {
        let dir = ctx.scratch("l5-rename"), mdir = ctx.scratch("l5-rename-widget")
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), widget = SharedStateStore(primaryDirectory: mdir)
        _ = try host.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [todayIso: []], fetchedRange: [todayIso],
                                          requestSeq: try host.reserveSnapshotSequence(), syncedAt: Date().addingTimeInterval(-60))
        let renamed = Club(id: 39, name: "Canary Wharf Renamed", shortCode: "CWR")
        _ = try widget.mergeAndSaveSnapshot(clubId: 39, clubs: [renamed], clubName: renamed.name, clubShortCode: renamed.shortCode, fetchedDays: [todayIso: []], fetchedRange: [todayIso],
                                            requestSeq: try widget.reserveSnapshotSequence(), syncedAt: Date().addingTimeInterval(-10))
        try host.repairSnapshotMirrorIfNeeded(clubId: 39)
        let kept = widget.loadSnapshot(clubId: 39)
        try assertTrue(kept?.clubName == renamed.name && kept?.clubShortCode == "CWR" && kept?.clubs == [renamed], "host mirror repair keeps the newer widget club name, short code, and clubs")
    }

    // An existing private mirror file that cannot be repaired is reported by reconciliation and in the menu.
    do {
        let dir = ctx.scratch("l5-reconcile"), mdir = ctx.scratch("l5-reconcile-widget"), kcU = ctx.keychain("l5-reconcile")
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        try loginSeed(st, memberA, kcU, [activeBooking(501, isoUTC(openSlot.start))])
        try "{\"bookedIds\":[999],\"ownerId\":\"stale\"}".write(to: mdir.appendingPathComponent("bookings.json"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: mdir.path)
        let thrown = denial { try st.reconcileAccountMirror(for: memberA, keychain: kcU) }
        let vm = ScheduleViewModel(store: st, keychain: kcU, client: mockPublicClient(store: st), bookingClient: MobileMock().client)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mdir.path)
        try assertTrue(!thrown.isEmpty && vm.bannerIsError && (vm.bannerMessage ?? "").contains("Could not sync local account files"),
                       "an unwritable existing private mirror is reported by reconcileAccountMirror and the menu")
    }

    // A failed widget preferences write during sign-in stays in the banner and is repaired by the next reconciliation.
    do {
        let f = try ctx.freshVM("l5-signin-mirror", mirror: true, seed: { st, _, _, _ in _ = try st.updatePreferences { $0.clubId = 220; $0.clubName = "Chelsea"; $0.clubShortCode = "CHE" } })
        let mirrorPrefs = f.mirror!.appendingPathComponent("preferences.json")
        try fm.setAttributes([.immutable: true], ofItemAtPath: mirrorPrefs.path)
        await signIn(f.vm)
        try fm.setAttributes([.immutable: false], ofItemAtPath: mirrorPrefs.path)
        let banner = f.vm.bannerMessage ?? ""
        let stale = SharedStateStore(primaryDirectory: f.mirror!).loadPreferences().clubId
        let repair = try f.store.reconcileAccountMirror(for: f.vm.memberSession, keychain: f.kc)
        try assertTrue(f.vm.memberSession?.token == "tok_A" && f.vm.bannerIsError && banner.contains("Signed in as") && banner.contains("updating the widget copy failed") && stale == 220,
                       "a failed widget preferences write during sign-in is kept in the sign-in banner")
        try assertTrue(repair == nil && SharedStateStore(primaryDirectory: f.mirror!).loadPreferences().clubId == 39 && f.store.loadPreferences().clubId == 39,
                       "the next reconciliation repairs the widget preferences without changing the club")
    }

    // Lock and curl deadlines follow the injected monotonic clock: a clock that jumps ahead ends every wait at once,
    // which no wall-clock reading (or rollback) could cause, and the timeouts are immutable.
    do {
        let ticks = Locked(0.0)
        let racing: @Sendable () -> TimeInterval = { var now = 0.0; ticks.mutate { $0 += 1; now = $0 }; return now }
        let dir = ctx.scratch("l5-clock")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let block = Locked(false), inHook = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let st = SharedStateStore(primaryDirectory: dir, lockTimeout: 30, uptime: racing, betweenWidgetReads: {
            if block.value { block.value = false; inHook.signal(); _ = resume.wait(timeout: .now() + 3) }
        })
        let fd = Darwin.open(dir.appendingPathComponent(".preferences.lock").path, O_CREAT | O_RDWR, 0o600)
        try assertTrue(fd >= 0 && flock(fd, LOCK_EX) == 0, "test holds .preferences.lock")
        let fileStart = Date()
        let fileDenied = denial { _ = try st.updatePreferences { $0.period = .evening } }
        let fileTime = Date().timeIntervalSince(fileStart)
        flock(fd, LOCK_UN); Darwin.close(fd)
        block.value = true
        let holder = Task.detached { st.readConsistentWidgetState() }
        try assertTrue(await waitFor(inHook), "another thread holds the store's in-process lock")
        let lockStart = Date()
        let lockDenied = denial { _ = try st.updatePreferences { $0.period = .evening } }
        let lockTime = Date().timeIntervalSince(lockStart)
        resume.signal(); _ = await holder.value
        let curlStart = Date()
        let curlDenied = denial { _ = try MobileBookingClient.runCurlSync(MobileRequest(method: "GET", url: "http://127.0.0.1:9/", headers: []),
                                                                          hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "exec /bin/sleep 10"], timeoutSeconds: 30, uptime: { racing() * 1000 })) }
        let curlTime = Date().timeIntervalSince(curlStart)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TertiaCore/SharedStateStore.swift"), encoding: .utf8)
        try assertTrue(fileDenied == StoreError.lockTimedOut(".preferences.lock").localizedDescription && fileTime < 0.5, "a contended lock file times out on the monotonic clock (30s timeout, \(String(format: "%.2f", fileTime))s real)")
        try assertTrue(lockDenied == StoreError.lockTimedOut(".preferences.lock").localizedDescription && lockTime < 0.5, "same-instance lock contention times out on the monotonic clock (\(String(format: "%.2f", lockTime))s real)")
        try assertTrue(curlDenied == "Network request timed out." && curlTime < 1.5, "the curl deadline follows the monotonic clock (30s timeout, \(String(format: "%.2f", curlTime))s real)")
        try assertTrue(source.contains("public let lockTimeout: TimeInterval") && source.contains("public let mutationLockTimeout: TimeInterval") && !source.contains("var lockTimeout"),
                       "lockTimeout and mutationLockTimeout are immutable let properties")
    }

    // A failed Keychain UI restore after a completed write is a warning: the write is not retried and every surface says so.
    do {
        let disables = Locked(0)
        let hooks = KeychainStore.Hooks(setInteractionAllowed: { allowed in if !allowed { disables.mutate { $0 += 1 }; return 0 }; return -50 })
        let kcW = ctx.keychain("l5-restore", hooks: hooks)
        let warning = try kcW.saveSession(memberA)
        let saveCalls = disables.value
        let read = try kcW.readSessionWithWarning()
        try assertTrue(warning == .interactionRestoreFailed(-50) && saveCalls == 2 && read.session == memberA && read.warning == .interactionRestoreFailed(-50),
                       "a failed restore returns a warning, the completed save is not retried, and reads report it")
        let f = try ctx.freshVM("l5-restore-vm", hooks: hooks)
        await signIn(f.vm)
        let signInBanner = f.vm.bannerMessage ?? ""
        f.vm.bannerMessage = nil
        f.vm.syncFromDisk()
        for _ in 0..<300 where !(f.vm.isShownDayCached() && !f.vm.isLoading) { try await Task.sleep(nanoseconds: 10_000_000) } // its load ends before the next test counts requests
        let restore = KeychainError.interactionRestoreFailed(-50).localizedDescription
        try assertTrue(f.vm.memberSession?.token == "tok_A" && f.mock.logins == 1 && signInBanner.contains(restore) && (f.vm.bannerMessage ?? "").contains(restore),
                       "sign-in completes once and reports the restore warning; a reload reports the read warning")
    }

    // Opening a cold menu sends 1 public request (never 2) and refreshes a stale cache; a notification still loads.
    do {
        MockHTTPBox.shared.set(39, body: page39, delay: 0.2)
        let cold = try ctx.freshVM("l5-appear")
        var before = MockHTTPBox.shared.count(39)
        cold.vm.handleAppear(); await cold.vm.load(forceRefresh: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        let coldRequests = MockHTTPBox.shared.count(39) - before
        let staleAt = Date().addingTimeInterval(-7200)
        let stale = try ctx.freshVM("l5-appear-stale", seed: { st, _, _, _ in
            try st.seedSnapshot(TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: []], syncedAt: staleAt, daySyncedAt: [todayIso: staleAt]))
        })
        before = MockHTTPBox.shared.count(39)
        stale.vm.handleAppear(); await stale.vm.load(forceRefresh: false)
        try await Task.sleep(nanoseconds: 400_000_000)
        let staleRequests = MockHTTPBox.shared.count(39) - before
        let notified = try ctx.freshVM("l5-appear-notify")
        before = MockHTTPBox.shared.count(39)
        notified.vm.syncFromDisk()
        for _ in 0..<100 where !(notified.vm.isShownDayCached() && !notified.vm.isLoading) { try await Task.sleep(nanoseconds: 10_000_000) }
        let notifyRequests = MockHTTPBox.shared.count(39) - before
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(coldRequests == 1 && cold.vm.isShownDayCached() && staleRequests == 1 && (stale.vm.snapshot?.syncedAt(for: todayIso) ?? .distantPast) > staleAt && notifyRequests == 1,
                       "handleAppear plus the view's load sends 1 public request cold (\(coldRequests)) and 1 for a stale cache (\(staleRequests)); a notification still loads (\(notifyRequests))")
    }

    // Duplicate active booking IDs: the first entry rules visibility and cancellation alike.
    do {
        let noon = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "12:00")!
        let pastRow = ClassSession(id: 701, date: todayIso, startTime: "11:44", endTime: "12:30", durationMinutes: 46, title: "Past", trainer: "", clubName: "Canary Wharf")
        let futureRow = ClassSession(id: 702, date: todayIso, startTime: "18:00", endTime: "18:45", durationMinutes: 45, title: "Future", trainer: "", clubName: "Canary Wharf")
        let later = isoUTC(noon.addingTimeInterval(3 * 3600))
        for first in ["not-a-date", ""] {
            let st = SharedStateStore(primaryDirectory: ctx.scratch("l5-dupes"))
            let vm = ScheduleViewModel(store: st, keychain: ctx.keychain("l5-dupes"), client: mockPublicClient(store: st), bookingClient: MobileMock().client)
            vm.snapshot = TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: [pastRow, futureRow]], syncedAt: noon, daySyncedAt: [todayIso: noon])
            vm.memberSession = memberA
            vm.bookings = BookingsSnapshot(ownerKey: memberA.ownerKey!, bookings: [701, 701, 702, 702].enumerated().map { activeBooking($0.element, $0.offset % 2 == 0 ? first : later) }, syncedAt: noon)
            let visible = Set(vm.filteredClasses(now: noon).map(\.id))
            for row in [pastRow, futureRow] {
                let authorized = (try? BookingAuthorization.authorizeCancellation(classId: row.id, bookings: vm.bookings, confirmedLate: true, now: noon) { (row, 39, "Canary Wharf") }) != nil
                try assertEqual(vm.cardInputs(for: row, now: noon).canCancelBooked, authorized, "first entry '\(first)': the badge and authorizeCancellation agree for row \(row.id)")
                if !visible.contains(row.id) { try assertTrue(!authorized, "first entry '\(first)': a hidden row \(row.id) is never cancellable") }
            }
            try assertTrue(!visible.contains(701) && visible.contains(702), "first entry '\(first)': a later valid duplicate never keeps a started row visible")
        }
    }

    // A class that starts during a bookings refresh is dropped; a default-date timetable fetched across London
    // midnight drops classes that had already started.
    do {
        let dir = ctx.scratch("l5-started"), kcS = ctx.keychain("l5-started"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock()
        try loginSeed(st, memberA, kcS, [])
        let start = Date().addingTimeInterval(3600)
        mock.bookings.value["tok_A"] = classesJSON([(801, isoUTC(start)), (802, isoUTC(start.addingTimeInterval(7200)))])
        let result = try await TertiaCLI.memberBookings(refresh: true, store: st, keychain: kcS, bookingClient: mock.client, nowProvider: { @Sendable in
            mock.requests.value.contains { $0.url.contains("/member/classes?") } ? start.addingTimeInterval(1) : start.addingTimeInterval(-60)
        })
        try assertEqual(result.snapshot.bookings.map(\.id), [802], "a class starting while the refresh was in flight is excluded (now sampled after the sync)")
        // Undated query fetched at 23:58 and answered at 00:01: it lists the new London day (zero grace), so the class
        // that started at 23:59 is gone and the 00:05 class tomorrow is listed.
        let tomorrow = LondonCalendar.addDays(to: todayIso, days: 1)!
        let ttDir = ctx.scratch("l5-midnight"), ttStore = SharedStateStore(primaryDirectory: ttDir)
        MockHTTPBox.shared.set(39, body: timetableHTML([Fx(id: 811, slot: at(todayIso, "23:59"), title: "Late Ride"), Fx(id: 812, slot: at(tomorrow, "00:05"), title: "Dawn Ride")],
                                                       emptyDays: (0...3).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) }))
        let calls = Locked(0)
        let beforeMidnight = at(todayIso, "23:58").start, afterMidnight = at(tomorrow, "00:01").start
        let crossing = try await TertiaCLI.queryTimetable(clubId: 39, date: nil, period: nil, search: nil, refresh: true, store: ttStore, client: mockPublicClient(store: ttStore),
                                                          nowProvider: { @Sendable in var n = 0; calls.mutate { $0 += 1; n = $0 }; return n == 1 ? beforeMidnight : afterMidnight })
        let evening = try await TertiaCLI.queryTimetable(clubId: 39, date: nil, period: nil, search: nil, refresh: true, store: ttStore, client: mockPublicClient(store: ttStore),
                                                         nowProvider: { @Sendable in beforeMidnight })
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(crossing.date == tomorrow && crossing.classes.map(\.id) == [812] && evening.date == todayIso && evening.classes.map(\.id) == [811],
                       "an undated timetable fetched at 23:58 and answered at 00:01 lists tomorrow without the 23:59 class that started")
    }

    // MCP get_timetable rejects a period outside its enum before any fetch; the 4 valid periods pass.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l5-mcp")), pub = mockPublicClient(store: st)
        func call(_ period: String) async -> String? {
            await MCPServer.handleLine("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"get_timetable\",\"arguments\":{\"club_id\":39,\"period\":\"\(period)\"}}}",
                                       store: st, keychain: ctx.keychain("l5-mcp"), client: pub, bookingClient: MobileMock().client)
        }
        let before = MockHTTPBox.shared.count(39)
        let invalid = try errorCode(await call(" brunch"))
        let fetches = MockHTTPBox.shared.count(39) - before
        var valid: [Bool] = []
        for period in ["all", "morning", "afternoon", "evening"] { valid.append(try toolResult(await call(period)).isError == false) }
        try assertTrue(invalid == -32602 && fetches == 0 && valid == [true, true, true, true], "MCP period ' brunch' is -32602 with 0 public fetches; all, morning, afternoon, evening pass")
    }

    // Parser: raw-text decoys (including a self-closed <textarea/>) and a carriage-return-ended comment.
    let real = "<script>let clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {};</script>"
    for (label, html) in [("<textarea><script> decoy", "<textarea><script>let clubs=[{\"id\":1,\"name\":\"Decoy\"}];</script></textarea>" + real),
                          ("<textarea/> decoy", "<textarea/>decoy <script>let clubs=[{\"id\":1,\"name\":\"Decoy\"}];</script></textarea>" + real),
                          ("CR-ended comment", "<script>// let clubs = [{\"id\":1,\"name\":\"Decoy\"}];\rlet clubs = [{\"id\":39,\"name\":\"Canary Wharf\"}];\nlet timetable = {};</script>")] {
        try assertEqual((try? HTMLTimetableParser.parse(html: html))?.clubs.map(\.id), [39], "parser: \(label)")
    }

    // An oversized public page is rejected; an oversized MCP line gets -32600 and the next line is served.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l5-oversize"))
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockTimetableURLProtocol.self]
        let small = PublicTimetableClient(store: st, session: URLSession(configuration: cfg), maxResponseBytes: 1000)
        let tooLarge = await denialAsync { _ = try await small.fetchSchedule(clubId: 39, date: todayIso, forceRefresh: true) }
        let input = ctx.scratch("l5-mcp-lines")
        try Data((String(repeating: "x", count: 500) + "\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n").utf8).write(to: input)
        let saved = dup(STDIN_FILENO), fd = Darwin.open(input.path, O_RDONLY)
        guard saved >= 0, fd >= 0, dup2(fd, STDIN_FILENO) >= 0 else { throw AssertionFailure(description: "FAIL: stdin redirection setup") }
        close(fd)
        let served = try await captureOutput { await MCPServer.run(store: st, keychain: ctx.keychain("l5-mcp-lines"), client: mockPublicClient(store: st), bookingClient: MobileMock().client, maxLineBytes: 64); return 0 }
        guard dup2(saved, STDIN_FILENO) >= 0 else { throw AssertionFailure(description: "FAIL: stdin restore") }
        close(saved); clearerr(stdin)
        let lines = served.out.split(separator: "\n").map(String.init)
        try assertTrue(tooLarge == ClientError.responseTooLarge(1000).localizedDescription, "a public page larger than maxResponseBytes is rejected")
        try assertTrue(lines.count == 2 && (try errorCode(lines[0])) == -32600 && lines[1].contains("\"id\":9") && lines[1].contains("\"result\""), "an oversized MCP line is -32600 and the next ping is answered")
    }

    // The preview clock: the sync time is never after the shown time, and the booked sample has not started.
    do {
        let offline = SampleData.previewScene(live: nil, now: Date())
        try assertTrue(LondonCalendar.formatSyncTime(offline.now) == "06:00" && offline.snapshot.syncedAt <= offline.now && offline.snapshot.daySyncedAt.values.allSatisfy { $0 <= offline.now }
                       && offline.bookedRow?.startTime == "07:00", "offline previews run at 06:00 with every day synced at or before 06:00")
        let noon = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "12:00")!
        let rows = ["11:55", "12:30", "13:00", "14:00", "15:00", "16:00"].enumerated().map { i, t in
            ClassSession(id: 900 + i, date: todayIso, startTime: t, endTime: "23:00", durationMinutes: 45, title: "Row \(t)", trainer: "", clubName: "Canary Wharf")
        }
        let live = TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [todayIso: rows], syncedAt: noon.addingTimeInterval(600), daySyncedAt: [todayIso: noon.addingTimeInterval(600)])
        let scene = SampleData.previewScene(live: live, now: noon)
        try assertTrue(scene.now == noon && scene.bookedRow?.id == 901 && scene.snapshot.syncedAt(for: todayIso) == noon,
                       "with a class that started 5 minutes ago, the booked sample is the next class (zero grace) and the sync time is the preview clock")
    }
}

/// Loop 6: pre-registered logins, execution-time clocks in the handoff, club-guarded menu actions, independent mirror
/// cleanup, revision-checked commits, ordered refreshes, mutation-lock probes, public-only Retry, signed-out adoption,
/// single locked reloads, bounded widget reads, widget metadata, Keychain warnings, the gallery clock, preview parity,
/// timetable dates, parser and MCP edges, curl deadlines and trailers, and the build scripts.
@MainActor func loop6(_ ctx: TestContext) async throws {
    let fm = ctx.fm, root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let accepted = Data("{\"statusCode\":\"accepted\"}".utf8), stale = ScheduleViewModel.staleIntentMessage
    MockHTTPBox.shared.set(39, body: page39)

    // A login paused at the server keeps its begin revision: a sign-out or another sign-in that completes meanwhile wins.
    for other in ["sign-out", "sign-in B"] {
        let dir = ctx.scratch("l6-paused-\(other.hasPrefix("sign-out") ? "out" : "in")"), kcP = ctx.keychain("l6-paused"), st = SharedStateStore(primaryDirectory: dir)
        if other == "sign-out" { try loginSeed(st, memberB, kcP, []) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            if req.url.contains("/auth/login") { entered.signal(); _ = await waitFor(release, seconds: 4); return (200, Data(loginJSON(token: "tok_A", id: 7, email: "a@example.com").utf8)) }
            return (200, Data(classesJSON([]).utf8))
        }
        let vm = ScheduleViewModel(store: st, keychain: kcP, client: mockPublicClient(store: st), bookingClient: client)
        vm.emailInput = "a@example.com"; vm.passwordInput = "x"
        let signing = Task { await vm.signIn() }
        try assertTrue(await waitFor(entered), "\(other): login A is paused at the server")
        let second = SharedStateStore(primaryDirectory: dir)
        if other == "sign-out" { _ = try second.clearSession(keychain: kcP) } else { try second.commitLogin(memberB, keychain: kcP) }
        release.signal()
        await signing.value
        let expected = other == "sign-out" ? nil : "tok_B"
        try assertTrue(try kcP.readSession()?.token == expected && vm.memberSession?.token == expected && vm.bannerMessage == BookingClientError.sessionSuperseded.localizedDescription,
                       "\(other) during a paused login A survives on disk and in the menu (A is discarded)")
    }

    // The execution clock is read again inside the transport handoff: crossing into the 3-hour window unconfirmed, or
    // past the start, refuses there with 0 cancellations sent; a confirmed cancel crossing into the window sends late.
    do {
        let dir = ctx.scratch("l6-clock"), kcT = ctx.keychain("l6-clock"), st = SharedStateStore(primaryDirectory: dir)
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 4 * 3600).rounded(.down))
        try loginSeed(st, memberA, kcT, [])
        let sent = Locked<[MobileRequest]>([])
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { final in sent.mutate { $0.append(final) } }
            return req.url.contains("/member/classes?") ? (200, Data(classesJSON([]).utf8)) : (200, accepted)
        }
        for (label, confirmed, offsets, expectation) in [
            ("unconfirmed 3h00m01s -> 3h00m00s", false, [-10_801.0, -10_800], "3 hours or less"),
            ("confirmed, crossing the start", true, [-10.0, 1], "already started"),
            ("confirmed 3h00m01s -> 3h00m00s", true, [-10_801.0, -10_800], ""),
        ] {
            try syncSeed(st, memberA, kcT, [activeBooking(601, isoUTC(start))])
            let calls = Locked(0), before = sent.value.count
            let thrown = await denialAsync {
                _ = try await client.mutateAndSync(classId: 601, isCancel: true, session: memberA, store: st, keychain: kcT) { _, bookings, _ in
                    var n = 0; calls.mutate { $0 += 1; n = $0 }
                    // Call 1 is beginMutation, call 2 the early gate check, call 3 the transport handoff itself.
                    return try BookingAuthorization.authorize(classId: 601, isCancel: true, bookings: bookings, confirmedLate: confirmed,
                                                              now: start.addingTimeInterval(offsets[min(n, offsets.count) - 1])) { .missing }
                }
            }
            let cancels = sent.value.dropFirst(before).filter { $0.url.contains("cancel_booking") }
            if expectation.isEmpty {
                try assertTrue(thrown.isEmpty && calls.value == 2 && cancels.map(\.body) == ["{\"classId\":601,\"lateBooking\":true}"], "\(label): the late flag of the final handoff check is sent")
            } else {
                try assertTrue(thrown.contains(expectation) && calls.value == 2 && cancels.isEmpty && st.loadBookings(for: memberA) != nil, "\(label): refused inside the handoff with 0 cancellations sent (\(thrown))")
            }
        }
    }

    // A menu Cancel queued behind another process's .mutation.lock is refused when the selected club changed meanwhile,
    // even though the booking's own start stamp would allow it (0 cancellation requests).
    do {
        let f = try ctx.freshVM("l6-queued-cancel")
        f.mock.bookings.value["tok_A"] = classesJSON([(501, isoUTC(openSlot.start))])
        await signIn(f.vm)
        await f.vm.load(forceRefresh: false)
        try assertTrue(f.vm.bookings?.bookedIds == [501] && f.vm.canUseBookingActions, "queued cancel: 501 is booked and actionable")
        let holder = SharedStateStore(primaryDirectory: f.dir), held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let lockTask = Task.detached { try await holder.withMutationLock(classId: 999) { held.signal(); _ = await waitFor(release, seconds: 4) } }
        try assertTrue(await waitFor(held), "another process holds .mutation.lock")
        let before = f.mock.count
        let queued = Task { try await click(f.vm, open501) }
        for _ in 0..<1000 where f.vm.busyClassId != 501 { await Task.yield() }
        try assertEqual(f.vm.busyClassId, 501, "the Cancel click is queued behind the lock")
        try SharedStateStore(primaryDirectory: f.dir).updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" }
        release.signal()
        try await queued.value
        _ = try? await lockTask.value
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale && f.vm.preferences.clubId == 200 && f.store.loadBookings(for: memberA)?.bookedIds == [501],
                       "a queued Cancel whose club changed before the lock is refused (0 cancellation requests, cache still valid)")
        let early = f.mock.count
        await f.vm.handleClassAction(classId: 501, expectedCancel: true, expectedToken: "tok_A", expectedClubId: 39, title: "Open Reformer", startTime: openSlot.time,
                                     expectedDate: openSlot.date)
        try assertTrue(f.mock.count == early && f.vm.bannerMessage == stale, "a click drawn for another club is refused on entry (0 requests)")
    }

    // B signs in over A while the widget's account.json cannot be replaced, then B's follow-up sync fails: A's widget
    // bookings.json is still removed on its own, so the widget shows no badges.
    do {
        let dir = ctx.scratch("l6-pinned"), mdir = ctx.scratch("l6-pinned-widget"), kcW = ctx.keychain("l6-pinned"), mock = MobileMock()
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        try loginSeed(st, memberA, kcW, [activeBooking(501, isoUTC(openSlot.start))])
        try assertEqual(SharedStateStore(primaryDirectory: mdir).loadBookedIds(), [501], "the widget shows A's booking")
        let pinned = mdir.appendingPathComponent("account.json")
        try fm.setAttributes([.immutable: true], ofItemAtPath: pinned.path)
        let committed = Result { try st.commitLogin(memberB, keychain: kcW) }
        mock.classesStatus.value["tok_B"] = 503
        let followUp = await denialAsync { _ = try await mock.client.syncBookings(for: memberB, store: st, keychain: kcW) }
        try fm.setAttributes([.immutable: false], ofItemAtPath: pinned.path)
        try assertTrue((try? committed.get())?.cacheError != nil && !followUp.isEmpty && !fm.fileExists(atPath: mdir.appendingPathComponent("bookings.json").path)
                       && SharedStateStore(primaryDirectory: mdir).loadBookedIds() == [] && (try kcW.readSession())?.token == "tok_B",
                       "an unreplaceable widget account.json never keeps A's widget bookings.json (removed independently; widget shows [])")
    }

    // bookings.json lands but the primary account.json that validates it fails: a reopened store rejects the mismatch.
    do {
        let dir = ctx.scratch("l6-half-commit"), kcH = ctx.keychain("l6-half-commit"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcH, [activeBooking(501, isoUTC(openSlot.start))])
        let started = try st.beginBookingsSync(for: memberA, keychain: kcH), marker = dir.appendingPathComponent("account.json")
        try fm.setAttributes([.immutable: true], ofItemAtPath: marker.path)
        let failed = denial { _ = try st.commitSyncedBookings([activeBooking(502, isoUTC(openSlot.start))], for: memberA, started: started, keychain: kcH) }
        try fm.setAttributes([.immutable: false], ofItemAtPath: marker.path)
        let onDisk = try String(contentsOf: dir.appendingPathComponent("bookings.json"), encoding: .utf8)
        let reopened = SharedStateStore(primaryDirectory: dir)
        try assertTrue(!failed.isEmpty && onDisk.contains("502") && reopened.loadBookings(for: memberA) == nil && !reopened.loadBookedIds().contains(502),
                       "a bookings.json whose account.json write failed carries an unvalidated revision: the reopened store's bookings and booked IDs reject it")
    }

    // Overlapping refreshes of one account commit in request order: B (started later, 2 bookings) wins whichever
    // finishes first.
    for order in ["A then B", "B then A"] {
        let dir = ctx.scratch("l6-overlap"), kcO = ctx.keychain("l6-overlap"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcO, [])
        let a = try st.beginBookingsSync(for: memberA, keychain: kcO), b = try st.beginBookingsSync(for: memberA, keychain: kcO)
        let one = [activeBooking(501, isoUTC(openSlot.start))], two = one + [activeBooking(503, isoUTC(farSlot.start))]
        if order == "A then B" { _ = try st.commitSyncedBookings(one, for: memberA, started: a, keychain: kcO); _ = try st.commitSyncedBookings(two, for: memberA, started: b, keychain: kcO) }
        else { _ = try st.commitSyncedBookings(two, for: memberA, started: b, keychain: kcO); _ = try st.commitSyncedBookings(one, for: memberA, started: a, keychain: kcO) }
        try assertEqual(SharedStateStore(primaryDirectory: dir).loadBookings(for: memberA)?.bookedIds, [501, 503], "overlapping refreshes, \(order): the later request's bookings stand")
    }
    // B (started later) fails at the server with a real 503, before or after A commits: A's 1 booking stands either way.
    for bFailsFirst in [true, false] {
        let dir = ctx.scratch("l6-overlap-503"), kcO = ctx.keychain("l6-overlap-503"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcO, [])
        let gates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)], arrived = DispatchSemaphore(value: 0), seen = Locked(0)
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            var n = 0; seen.mutate { n = $0; $0 += 1 }
            arrived.signal()
            _ = await waitFor(gates[min(n, 1)], seconds: 4)
            return n == 0 ? (200, Data(classesJSON([(501, isoUTC(openSlot.start))]).utf8)) : (503, Data("{}".utf8))
        }
        let a = Task { try await client.syncBookings(for: memberA, store: st, keychain: kcO) }
        try assertTrue(await waitFor(arrived), "A's refresh reached the server")
        let b = Task { try await client.syncBookings(for: memberA, store: st, keychain: kcO) }
        try assertTrue(await waitFor(arrived), "B's refresh reached the server")
        var bError = ""
        if bFailsFirst { gates[1].signal(); bError = await denialAsync { _ = try await b.value }; gates[0].signal(); _ = try await a.value }
        else { gates[0].signal(); _ = try await a.value; gates[1].signal(); bError = await denialAsync { _ = try await b.value } }
        try assertTrue(bError.contains("503") && SharedStateStore(primaryDirectory: dir).loadBookings(for: memberA)?.bookedIds == [501],
                       "overlapping refreshes, B fails with 503 \(bFailsFirst ? "before" : "after") A commits: A's booking stands (\(bError))")
    }

    // An unreadable .mutation.lock is never treated as idle: before the fetch 0 private requests, before the commit 0 cache writes.
    do {
        let dir = ctx.scratch("l6-lockprobe"), kcL = ctx.keychain("l6-lockprobe"), st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcL, [activeBooking(501, isoUTC(openSlot.start))])
        let lockFile = dir.appendingPathComponent(".mutation.lock"), requests = Locked(0), files = Locked<[Data?]>([])
        func cacheFiles() -> [Data?] { ["bookings.json", "account.json"].map { fm.contents(atPath: dir.appendingPathComponent($0).path) } }
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            requests.mutate { $0 += 1 }
            files.value = ["bookings.json", "account.json"].map { FileManager.default.contents(atPath: dir.appendingPathComponent($0).path) }
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockFile.path)
            return (200, Data(classesJSON([(502, isoUTC(openSlot.start))]).utf8))
        }
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockFile.path)
        let beforeFetch = await denialAsync { _ = try await client.syncBookings(for: memberA, store: st, keychain: kcL) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFile.path)
        try assertTrue(!beforeFetch.isEmpty && requests.value == 0, "an unreadable .mutation.lock before the fetch sends 0 private requests (\(beforeFetch))")
        let beforeCommit = await denialAsync { _ = try await client.syncBookings(for: memberA, store: st, keychain: kcL) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFile.path)
        try assertTrue(!beforeCommit.isEmpty && requests.value == 1 && cacheFiles() == files.value && st.loadBookings(for: memberA)?.bookedIds == [501],
                       "an unreadable .mutation.lock before the commit writes 0 cache files (\(beforeCommit))")
    }

    // Signed in, the "Schedule unavailable" Retry is public only; the header Refresh is public plus one private sync.
    do {
        let f = try ctx.freshVM("l6-retry")
        await signIn(f.vm)
        MockHTTPBox.shared.set(39, status: 500, body: "down")
        await f.vm.load(forceRefresh: false)
        let blank = f.vm.snapshot?.hasCachedDay(f.vm.effectiveSelectedDate()) != true
        if blank { f.vm.snapshot = nil }
        await f.vm.retryPublicSchedule()
        try assertTrue(f.vm.errorMessage != nil, "the public site is down: Schedule unavailable")
        var (pub, priv) = (MockHTTPBox.shared.count(39), f.mock.count)
        await f.vm.retryPublicSchedule()
        try assertTrue(MockHTTPBox.shared.count(39) == pub + 1 && f.mock.count == priv, "Retry sends 1 public request and 0 private requests")
        (pub, priv) = (MockHTTPBox.shared.count(39), f.mock.count)
        await f.vm.load(forceRefresh: true)
        try assertTrue(MockHTTPBox.shared.count(39) == pub + 1 && f.mock.count == priv + 1, "the header Refresh sends 1 public request and 1 private request")
        MockHTTPBox.shared.set(39, body: page39)
    }

    // A session expiry at member-only club 250 adopts Canary Wharf (39) in the open menu and on disk before other
    // surfaces are notified, without reopening the menu.
    do {
        let extra = Club(id: 250, name: "Zeta Extra", shortCode: "ZX")
        let member250 = MemberSession(token: "tok_250", id: 25, name: "Z", email: "z@example.com", homeClubId: 250, homeClubName: "Zeta Extra", expiresAt: "", clubs: [extra])
        let box = Locked<ScheduleViewModel?>(nil), notified = Locked<[Int]>([])
        let f = try ctx.freshVM("l6-expiry-250", mirror: true, onChange: { MainActor.assumeIsolated { notified.mutate { $0.append(box.value?.preferences.clubId ?? -1) } } },
                                seed: { st, kcV, _, _ in
            try st.seedSnapshot(TimetableSnapshot(clubs: Club.defaultClubs + [extra], clubId: 52, clubName: "Soho", clubShortCode: "SOHO", days: [:], syncedAt: Date()))
            try kcV.saveSession(member250)
        })
        box.value = f.vm
        try assertEqual(f.vm.preferences.clubId, 250, "the member-only club 250 is selected")
        f.mock.classesStatus.value["tok_250"] = 401
        await f.vm.load(forceRefresh: true)
        try assertTrue(f.vm.memberSession == nil && f.vm.preferences.clubId == 39 && f.vm.availableClubs.count == 17 && f.store.loadPreferences().clubId == 39
                       && SharedStateStore(primaryDirectory: f.mirror!).loadPreferences().clubId == 39 && notified.value.first == 39,
                       "expiry at club 250 adopts club 39 in the open menu, both preference files, and before the first notification (\(notified.value))")
    }

    // An account switch forced inside the reload's locked read waits for it: the menu shows A with A's bookings, then
    // B with B's bookings, never a mix.
    do {
        let service = ctx.keychainService("l6-switch"), armed = Locked(false)
        let dir = ctx.scratch("l6-switch"), switcher = SharedStateStore(primaryDirectory: dir), switcherKC = KeychainStore(service: service, account: "verify")
        let switched = DispatchSemaphore(value: 0)
        let kcV = KeychainStore(service: service, account: "verify", hooks: .init(getInteractionAllowed: {
            var fire = false
            armed.mutate { fire = $0; $0 = false }
            if fire {
                Thread.detachNewThread {
                    _ = try? switcher.commitLogin(memberB, keychain: switcherKC)
                    try? syncSeed(switcher, memberB, switcherKC, [activeBooking(601, isoUTC(openSlot.start))])
                    switched.signal()
                }
                usleep(150_000) // the switch is now waiting on .account.lock
            }
            return (0, true)
        }))
        let st = SharedStateStore(primaryDirectory: dir)
        try loginSeed(st, memberA, kcV, [activeBooking(501, isoUTC(openSlot.start))])
        let vm = ScheduleViewModel(store: st, keychain: kcV, client: mockPublicClient(store: st), bookingClient: MobileMock().client)
        armed.value = true
        vm.syncFromDisk()
        let first = (vm.memberSession?.name, vm.bookings?.bookedIds)
        try assertTrue(await waitFor(switched), "the forced switch to B completes after the read")
        vm.syncFromDisk()
        try assertTrue(first.0 == "A" && first.1 == [501] && vm.memberSession?.name == "B" && vm.bookings?.bookedIds == [601] && vm.emailInput == "b@example.com",
                       "a switch forced mid-reload never pairs one account's name with the other's bookings (\(first))")
    }

    // Sign-out reconciles a stale widget club (250) to the primary club (Soho, 52).
    do {
        let soho = Club(id: 52, name: "Soho", shortCode: "SOHO")
        let memberS = MemberSession(token: "tok_S", id: 52, name: "S", email: "s@example.com", homeClubId: 52, homeClubName: "Soho", expiresAt: "", clubs: [soho, canary])
        let f = try ctx.freshVM("l6-signout-mirror", mirror: true, seed: { st, kcV, _, _ in
            try kcV.saveSession(memberS)
            try st.seedPreferences(TertiaPreferences(clubId: 52, clubName: "Soho", clubShortCode: "SOHO"))
        })
        try SharedStateStore(primaryDirectory: f.mirror!).seedPreferences(TertiaPreferences(clubId: 250, clubName: "Zeta Extra", clubShortCode: "ZX"))
        f.vm.signOut()
        try assertTrue(f.store.loadPreferences().clubId == 52 && SharedStateStore(primaryDirectory: f.mirror!).loadPreferences().clubId == 52 && f.vm.preferences.clubId == 52,
                       "sign-out rewrites a stale widget club 250 to the primary club 52")
    }

    // Another holder of the same store's in-process lock past lockTimeout: the widget read returns within its bound with no badges.
    do {
        let dir = ctx.scratch("l6-bounded"), kcB = ctx.keychain("l6-bounded"), st = SharedStateStore(primaryDirectory: dir, lockTimeout: 0.3)
        try loginSeed(st, memberA, kcB, [activeBooking(501, isoUTC(openSlot.start))])
        try assertEqual(st.readConsistentWidgetState().bookedIds, [501], "unlocked, the widget read shows the booking")
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        Thread.detachNewThread { _ = try? st.withAuthorizedTransportHandoff(for: memberA, keychain: kcB) { _ in held.signal(); _ = release.wait(timeout: .now() + 3) } }
        try assertTrue(await waitFor(held), "another thread holds the store lock")
        let began = Date()
        let state = st.readConsistentWidgetState()
        let elapsed = Date().timeIntervalSince(began)
        release.signal()
        try assertTrue(state.bookedIds.isEmpty && elapsed < 1.0, "readConsistentWidgetState returns in \(String(format: "%.2f", elapsed))s with no booked IDs while the lock is held")
    }

    // Club metadata in the widget copy: a later widget rename (lower request number, newer metaUpdatedAt) beats an
    // earlier host snapshot with a high request number.
    do {
        let dir = ctx.scratch("l6-meta"), mdir = ctx.scratch("l6-meta-widget")
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), widget = SharedStateStore(primaryDirectory: mdir)
        let t0 = Date().addingTimeInterval(-600), t1 = Date().addingTimeInterval(-60), day = [todayIso: [ClassSession]()]
        _ = try host.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: day, fetchedRange: [todayIso],
                                          requestSeq: 9_000_000_000_000_000, syncedAt: t0)
        _ = try widget.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf Riverside", clubShortCode: "CWR", fetchedDays: day, fetchedRange: [todayIso],
                                            requestSeq: 5, syncedAt: t1)
        try host.repairSnapshotMirrorIfNeeded(clubId: 39)
        try assertEqual(widget.loadSnapshot(clubId: 39)?.clubName, "Canary Wharf Riverside", "the newer widget club name wins over the host's higher request number")
    }

    // A conditional sign-out keeps the Keychain warning of its pre-delete read, whether the token matched or not.
    do {
        let failRestore = Locked(false)
        let kcW = ctx.keychain("l6-warning", hooks: .init(getInteractionAllowed: { (0, true) }, setInteractionAllowed: { allowed in
            var fail = false
            if allowed { failRestore.mutate { fail = $0; $0 = false } }
            return fail ? -25308 : 0
        }))
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l6-warning"))
        try loginSeed(st, memberA, kcW, [])
        failRestore.value = true
        let mismatch = try st.clearSession(expectedSession: memberB, keychain: kcW)
        failRestore.value = true
        let match = try st.clearSession(expectedSession: memberA, keychain: kcW)
        try assertTrue(!mismatch.didClear && mismatch.warning == .interactionRestoreFailed(-25308)
                       && match.didClear && match.warning == .interactionRestoreFailed(-25308) && (try kcW.readSession()) == nil,
                       "clearSession(expectedSession:) returns the pre-delete read's restore warning on mismatch and on match")
    }

    // Widget gallery: at 20:00 London the gallery still shows sample classes (fixed 06:00 clock); a live widget with the
    // same 07:00..19:30 timetable shows none.
    do {
        let eight = at(todayIso, "20:00").start, gallery = widgetGalleryPreview(now: eight)
        try assertTrue(widgetUpcomingSessions(snapshot: gallery.snapshot, preferences: TertiaPreferences(), now: gallery.date).count == 6
                       && widgetUpcomingSessions(snapshot: SampleData.previewSnapshot(now: eight), preferences: TertiaPreferences(), now: eight).isEmpty
                       && LondonCalendar.formatSyncTime(gallery.date) == "06:00", "the widget gallery shows 6 sample classes at 20:00; the live widget at 20:00 shows none")
    }

    // README previews draw the shipped controls: the 10-day strip, the full club list, and the Quit button.
    do {
        let f = try ctx.freshVM("l6-parity")
        let live = MenuBarScheduleView(model: f.vm, onQuit: {}).controlSummary
        let frozen = MenuBarScheduleView(model: f.vm, onQuit: {}, staticPreview: true, previewNow: previewNow).controlSummary
        try assertTrue(live == frozen && live == (10, 17, true), "a static preview draws the live menu's controls (\(frozen))")
        guard let rendered = ctx.renderedPreviews else { throw AssertionFailure(description: "FAIL: widgetHarnessBinary did not render the previews") }
        let menus = ["menubar-dark.png", "menubar-club-open-dark.png", "menubar-light.png"]
        try assertTrue(menus.allSatisfy { rendered.stdout.contains("\($0) controls: 10 date pills, 17 clubs, quit true") }
                       && rendered.stdout.contains("menubar-booking-dark.png controls: 10 date pills, 1 clubs, quit true")
                       && (try fm.contentsOfDirectory(atPath: rendered.dir.path)).filter { $0.hasSuffix(".png") }.count == 8,
                       "render-previews draws 8 PNGs with the shipped 10-day strip, full club list, and Quit button")
        // The pixels, not only the printed summary: the PNG shows a Quit glyph and an 8th date pill; the same menu rendered
        // here without Quit fails that check (proving the check would catch a hidden Quit button).
        guard let png = NSBitmapImageRep(data: try Data(contentsOf: rendered.dir.appendingPathComponent("menubar-dark.png"))) else { throw AssertionFailure(description: "FAIL: menubar-dark.png does not decode") }
        let shipped = menuChrome(png)
        try assertTrue(shipped.iconButtons == 4 && shipped.quitGlyph && shipped.eighthPill, "menubar-dark.png shows 4 header icon buttons, a visible Quit glyph, and an 8th date pill (\(shipped))")
        f.vm.themeOverride = .dark
        func renderHere(onQuit: (() -> Void)?) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(content: MenuBarScheduleView(model: f.vm, onQuit: onQuit, staticPreview: true, previewNow: previewNow)); renderer.scale = 2
            guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { throw AssertionFailure(description: "FAIL: in-process menu render failed") }
            return rep
        }
        let withQuit = menuChrome(try renderHere(onQuit: {})), withoutQuit = menuChrome(try renderHere(onQuit: nil))
        try assertTrue(withQuit == shipped && withoutQuit.iconButtons == 3 && !(withoutQuit.iconButtons == 4 && withoutQuit.quitGlyph && withoutQuit.eighthPill),
                       "an in-process render with Quit matches the PNG; without Quit the pixel check fails (\(withQuit) vs \(withoutQuit))")
    }

    // An explicit date lists every stored row (even 2 days ago) in the CLI and MCP.
    do {
        let twoAgo = LondonCalendar.addDays(to: todayIso, days: -2)!, st = SharedStateStore(primaryDirectory: ctx.scratch("l6-history"))
        MockHTTPBox.shared.set(39, body: timetableHTML([Fx(id: 821, slot: at(twoAgo, "07:00"), title: "Old Ride"), Fx(id: 822, slot: at(twoAgo, "20:00"), title: "Old Flow")],
                                                       emptyDays: (0...3).compactMap { LondonCalendar.addDays(to: twoAgo, days: $0) }))
        let cli = try await TertiaCLI.queryTimetable(clubId: 39, date: twoAgo, period: nil, search: nil, refresh: true, store: st, client: mockPublicClient(store: st))
        let mcp = try toolResult(await MCPServer.handleLine("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"get_timetable\",\"arguments\":{\"club_id\":39,\"date\":\"\(twoAgo)\",\"refresh\":true}}}",
                                                            store: st, keychain: ctx.keychain("l6-history"), client: mockPublicClient(store: st), bookingClient: MobileMock().client))
        let mcpIds = ((try JSONSerialization.jsonObject(with: Data(mcp.text.utf8)) as? [String: Any])?["classes"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(cli.date == twoAgo && cli.classes.map(\.id) == [821, 822] && !mcp.isError && mcpIds == [821, 822], "a timetable query for 2 days ago returns every row in the CLI and MCP")
    }

    // An inert <script type="text/plain"> with empty declarations before the real script never hides its classes.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l6-inert"))
        MockHTTPBox.shared.set(39, body: "<script type=\"text/plain\">let clubs=[];let timetable={};</script>" + timetableHTML([Fx(id: 831, slot: openSlot, title: "Inert Guard")],
                                                                                                                              emptyDays: [openSlot.date]))
        let snap = try await mockPublicClient(store: st).fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true)
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(snap.session(id: 831) != nil && st.loadSnapshot(clubId: 39)?.session(id: 831) != nil, "classes after an inert script block are parsed and cached")
    }

    // Class ID 0 and conflicting duplicate IDs: the parser rejects the page; a legacy cache never offers those rows.
    do {
        let row = { (id: Int, title: String) in Fx(id: id, slot: openSlot, title: title) }
        for (label, page) in [("class ID 0", timetableHTML([row(0, "Zero")])), ("conflicting duplicate ID", timetableHTML([row(841, "One"), row(841, "Two")]))] {
            try assertTrue(!denial { _ = try HTMLTimetableParser.parse(html: page) }.isEmpty, "the parser rejects a page with \(label)")
        }
        let legacy = TimetableSnapshot(clubs: [canary], clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", days: [openSlot.date: [
            ClassSession(id: 0, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Zero", trainer: "", clubName: "Canary Wharf"),
            ClassSession(id: 841, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "One", trainer: "", clubName: "Canary Wharf"),
            ClassSession(id: 841, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Two", trainer: "", clubName: "Canary Wharf"),
            ClassSession(id: 842, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Fine", trainer: "", clubName: "Canary Wharf")]], syncedAt: Date())
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l6-legacy-ids"))
        try st.seedSnapshot(legacy)
        let cached = st.loadSnapshot(clubId: 39)
        try assertTrue(cached?.classes(for: openSlot.date).map(\.id) == [842] && cached?.session(id: 841) == nil && cached?.session(id: 0) == nil,
                       "a legacy cache with class ID 0 and a conflicting duplicate offers only the unambiguous row")
    }

    // curl deadlines on the monotonic clock: expired inside the handoff gate launches nothing; a jump during a
    // partial stdin write stops at once.
    do {
        let probe = MobileRequest(method: "GET", url: "http://127.0.0.1:9/", headers: [])
        let launched = ctx.scratch("l6-launched"), clock = Locked<TimeInterval>(0)
        let gated = denial {
            _ = try MobileBookingClient.runCurlSync(probe, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "touch '\(launched.path)'; cat >/dev/null; printf '\\n200'"],
                                                                        timeoutSeconds: 5, uptime: { clock.value }), gate: { request, handoff in clock.value += 60; try handoff(request) })
        }
        try assertTrue(gated == "Network request timed out." && !fm.fileExists(atPath: launched.path), "a deadline that expires while the handoff gate waits launches 0 curl processes")
        let calls = Locked(0), began = Date()
        let big = MobileRequest(method: "POST", url: "http://127.0.0.1:9/", headers: [], body: String(repeating: "a", count: 400_000))
        let jumped = denial {
            _ = try MobileBookingClient.runCurlSync(big, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "exec /bin/sleep 10"], timeoutSeconds: 20,
                                                                      uptime: { var n = 0; calls.mutate { $0 += 1; n = $0 }; return n <= 3 ? 0 : 1_000 }))
        }
        try assertTrue(jumped == "Network request timed out." && Date().timeIntervalSince(began) < 2 && calls.value >= 4,
                       "a clock jump between partial config writes stops the request at once (\(String(format: "%.2f", Date().timeIntervalSince(began)))s)")
        // curl's trailer is a newline plus a 3-digit status.
        for (output, status) in [("200", nil), ("\\n0200", nil), ("\\n204", 204)] as [(String, Int?)] {
            let result = Result { try MobileBookingClient.runCurlSync(probe, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "cat >/dev/null; printf '\(output)'"], timeoutSeconds: 5)) }
            let ok = status.map { s in (try? result.get()).map { $0.status == s && $0.data.isEmpty } == true } ?? ((result.error as? BookingClientError) == .invalidResponse)
            try assertTrue(ok, "curl output \(output.debugDescription) is \(status.map { "status \($0) with an empty body" } ?? "rejected as invalid")")
        }
    }

    // Scripts: default builds serialize on .build/.build.lock while private TERTIA_BUILD_DIR builds run side by side;
    // test.sh's watchdog has no bypass; check-test-python names the missing capability.
    do {
        let buildRoot = ctx.scratch("l6-build"), probe = buildRoot.appendingPathComponent("probe")
        for dir in ["Scripts", "fake-bin", "probe"] { try fm.createDirectory(at: buildRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Scripts/build.sh", "Scripts/publish.py"] { try fm.copyItem(at: root.appendingPathComponent(path), to: buildRoot.appendingPathComponent(path)) }
        let swiftc = "#!/bin/sh\nmkdir \"\(probe.path)/inside\" 2>/dev/null || : > \"\(probe.path)/overlapped\"\n/bin/sleep 0.15\nrmdir \"\(probe.path)/inside\" 2>/dev/null\nexit 0\n"
        for (path, text) in [("fake-bin/xcrun", "#!/bin/sh\necho /tmp\n"), ("fake-bin/swiftc", swiftc)] {
            try text.write(to: buildRoot.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: buildRoot.appendingPathComponent(path).path)
        }
        func twoBuilds(privateDirs: Bool) async throws -> (ok: Bool, overlapped: Bool) {
            try? fm.removeItem(at: probe.appendingPathComponent("overlapped"))
            let runs = (0..<2).map { i in
                Task.detached { () -> Int32 in
                    let env = ["PATH": "\(buildRoot.appendingPathComponent("fake-bin").path):/usr/bin:/bin",
                               "TERTIA_BUILD_DIR": privateDirs ? buildRoot.appendingPathComponent("private-\(i)").path : ""]
                    return (try? runSubprocess("/bin/bash", args: [buildRoot.appendingPathComponent("Scripts/build.sh").path], env: env, timeoutSeconds: 15))?.status ?? -1
                }
            }
            var statuses: [Int32] = []
            for run in runs { statuses.append(await run.value) }
            return (statuses == [0, 0], fm.fileExists(atPath: probe.appendingPathComponent("overlapped").path))
        }
        let shared = try await twoBuilds(privateDirs: false), privateRuns = try await twoBuilds(privateDirs: true)
        try assertTrue(shared.ok && !shared.overlapped && privateRuns.ok && privateRuns.overlapped,
                       "two default builds never overlap (.build/.build.lock); builds into private TERTIA_BUILD_DIRs run concurrently")
        let testScript = try String(contentsOf: root.appendingPathComponent("Scripts/test.sh"), encoding: .utf8)
        try assertTrue(!testScript.contains("--under-watchdog") && testScript.contains("run-watched --timeout 115") && testScript.contains("kill -TERM \"$!\"") && testScript.contains("exit 143' TERM INT"),
                       "test.sh's watchdog runs unconditionally and TERM runs its cleanup")
        for missing in ["TLSv1.3", "ALPN"] {
            let fake = ctx.scratch("l6-python-\(missing)")
            try "#!/bin/sh\necho \(missing)\n".write(to: fake, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
            let res = try runSubprocess("/usr/bin/python3", args: ["-I", root.appendingPathComponent("Scripts/publish.py").path, "print-test-python"], env: ["TERTIA_TEST_PYTHON": fake.path], timeoutSeconds: 10)
            try assertTrue(res.status == 1 && res.stderr.contains("lacks \(missing)"), "check-test-python names a missing \(missing)")
        }
    }

    // runSubprocess caps stdout and stderr independently and kills a flooding child at once.
    for stream in ["stdout", "stderr"] {
        let began = Date()
        let thrown = denial { _ = try runSubprocess("/bin/sh", args: ["-c", "head -c 300000 /dev/zero \(stream == "stderr" ? ">&2" : ""); exec /bin/sleep 10"], timeoutSeconds: 8, maxOutputBytes: 100_000) }
        try assertTrue(thrown.contains("more than 100000 bytes to \(stream)") && Date().timeIntervalSince(began) < 2, "runSubprocess stops a child flooding \(stream) (\(thrown))")
    }
}

/// Loop 7 regressions: account and credential races, late-cancel intent, ambiguous classes, empty-state copy, widget
/// timeline, preview scene, MCP framing, curl bounds, and the build scripts.
@MainActor func loop7(_ ctx: TestContext) async throws {
    let fm = ctx.fm, root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let accepted = Data("{\"statusCode\":\"accepted\"}".utf8), superseded = BookingClientError.sessionSuperseded.localizedDescription
    let restoreWarning = KeychainError.interactionRestoreFailed(-25308)
    MockHTTPBox.shared.set(39, body: page39)

    // The harness itself: a JSON-RPC error envelope, or a result without isError or text content, is never a tool result.
    for envelope in ["{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"Unknown tool\"}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}",
                     "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"isError\":false,\"content\":[]}}"] {
        try assertTrue(!denial { _ = try toolResult(envelope) }.isEmpty, "toolResult rejects \(envelope)")
    }

    // Login B begins while A is signed in; A's sign-out deletes the credential but cannot save its marker: B's commit is
    // refused by the credential digest (the revision never moved), and the Keychain stays empty.
    do {
        let dir = ctx.scratch("l7-login-digest"), kcD = ctx.keychain("l7-login-digest"), st = SharedStateStore(primaryDirectory: dir), marker = dir.appendingPathComponent("account.json")
        try loginSeed(st, memberA, kcD, [])
        let started = try st.beginLogin(keychain: kcD)
        try immutable(marker, true)
        let signOut = Result { try SharedStateStore(primaryDirectory: dir).clearSession(keychain: kcD) }
        try immutable(marker, false)
        let committed = denial { _ = try st.commitLogin(memberB, attempt: started.attempt, keychain: kcD) }
        try assertTrue((try? signOut.get())?.didClear == true && (try? signOut.get())?.cacheError != nil && committed == superseded && (try kcD.readSession()) == nil,
                       "a sign-out whose marker write failed still refuses a login begun before it (\(committed)); the Keychain stays empty")
    }

    // Two tokens of one member: tok_2's sign-in cannot write account.json and its refresh fails with 503. bookings.json
    // is removed anyway, and even tok_1's restored file is never usable by tok_2 (token digest).
    do {
        let dir = ctx.scratch("l7-two-tokens"), kcT = ctx.keychain("l7-two-tokens"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock()
        let tok1 = MemberSession(token: "tok_1", id: 7, name: "A", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
        let tok2 = MemberSession(token: "tok_2", id: 7, name: "A", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
        try loginSeed(st, tok1, kcT, [activeBooking(502, isoUTC(lateSlot.start))])
        let bookingsFile = dir.appendingPathComponent("bookings.json"), marker = dir.appendingPathComponent("account.json"), tok1Bookings = fm.contents(atPath: bookingsFile.path)
        try immutable(marker, true)
        let committed = Result { try st.commitLogin(tok2, keychain: kcT) }
        try immutable(marker, false)
        let removed = !fm.fileExists(atPath: bookingsFile.path)
        try tok1Bookings?.write(to: bookingsFile) // as if that removal had failed too
        let digestOnly = SharedStateStore(primaryDirectory: dir).loadBookings(for: tok2)
        mock.classesStatus.value["tok_2"] = 503
        let refresh = await denialAsync { _ = try await mock.client.syncBookings(for: tok2, store: st, keychain: kcT) }
        try assertTrue((try? committed.get())?.cacheError != nil && removed && tok1Bookings != nil && digestOnly == nil && refresh.contains("503")
                       && SharedStateStore(primaryDirectory: dir).loadBookings(for: tok2) == nil && (try kcT.readSession())?.token == "tok_2",
                       "tok_2 has 0 usable bookings after a blocked sign-in and a failed refresh (bookings.json removed; tok_1's file rejected by its digest)")
    }

    // An unconfirmed cancel crossing 3h00m01s -> 3h00m00s at the launch gate is refused with 0 requests and the cache stays
    // valid, so a confirmed retry succeeds at once (no Refresh); a reply lost after dispatch leaves bookingsValid false.
    do {
        let dir = ctx.scratch("l7-cross"), kcX = ctx.keychain("l7-cross"), st = SharedStateStore(primaryDirectory: dir)
        let start = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 4 * 3600).rounded(.down))
        try loginSeed(st, memberA, kcX, [activeBooking(601, isoUTC(start))])
        let sent = Locked<[MobileRequest]>([]), loseReply = Locked(false)
        let client = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { final in sent.mutate { $0.append(final) } }
            if req.url.contains("/member/classes?") { return (200, Data(classesJSON([]).utf8)) }
            if loseReply.value { throw BookingClientError.transportError("The reply was lost.") }
            return (200, accepted)
        }
        func cancel(confirmed: Bool, offsets: [Double]) async -> String {
            let calls = Locked(0)
            return await denialAsync {
                _ = try await client.mutateAndSync(classId: 601, isCancel: true, session: memberA, store: st, keychain: kcX) { _, bookings, _ in
                    var n = 0; calls.mutate { $0 += 1; n = $0 }
                    return try BookingAuthorization.authorize(classId: 601, isCancel: true, bookings: bookings, confirmedLate: confirmed,
                                                              now: start.addingTimeInterval(offsets[min(n, offsets.count) - 1])) { .missing }
                }
            }
        }
        func cancels() -> [String?] { sent.value.filter { $0.url.contains("cancel_booking") }.map(\.body) }
        let refused = await cancel(confirmed: false, offsets: [-10_801, -10_800])
        let afterRefusal = (cancels().count, st.loadBookings(for: memberA) != nil)
        let retried = await cancel(confirmed: true, offsets: [-10_800])
        try assertTrue(refused.contains("3 hours or less") && afterRefusal == (0, true) && retried.isEmpty && cancels() == ["{\"classId\":601,\"lateBooking\":true}"],
                       "a refusal at the launch gate sends 0 requests and keeps the cache valid; the confirmed retry sends 1 late cancel at once (\(refused))")
        try syncSeed(st, memberA, kcX, [activeBooking(601, isoUTC(start))])
        loseReply.value = true
        let lost = await cancel(confirmed: true, offsets: [-10_800])
        let markerJSON = (try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("account.json")))) as? [String: Any]
        try assertTrue(lost.contains("lost") && cancels().count == 2 && markerJSON?["bookingsValid"] as? Bool == false && st.loadBookings(for: memberA) == nil,
                       "a reply lost after dispatch leaves bookingsValid false (a Refresh is required)")
    }

    // The menu's original Cancel callback, called twice, arms the late confirmation and then is refused (0 requests); the
    // callback drawn after arming (the LATE CONFIRM button) sends exactly 1 late cancellation.
    do {
        let f = try ctx.freshVM("l7-double-cancel")
        f.mock.bookings.value["tok_A"] = classesJSON([(502, isoUTC(lateSlot.start))])
        await signIn(f.vm)
        await f.vm.load(forceRefresh: false)
        f.vm.selectedDate = lateSlot.date // the menu shows the row's day
        guard let late = f.vm.snapshot?.session(id: 502), let original = f.vm.classAction(for: late) else { throw AssertionFailure(description: "FAIL: 502 is not actionable in the menu") }
        let before = f.mock.count
        await original()
        let armed = f.vm.isConfirmingLateCancel(502)
        await original()
        let afterTwice = (f.mock.count, f.vm.isConfirmingLateCancel(502), f.vm.bannerMessage)
        guard let confirm = f.vm.classAction(for: late) else { throw AssertionFailure(description: "FAIL: the confirm button has no action") }
        await confirm()
        let lateCancels = f.mock.actions(after: before).filter { $0.url.contains("cancel_booking") }.map(\.body)
        try assertTrue(armed && afterTwice == (before, true, ScheduleViewModel.lateConfirmMessage) && lateCancels == ["{\"classId\":502,\"lateBooking\":true}"],
                       "the original Cancel callback twice sends 0 requests; the drawn confirm callback sends 1 late cancel (\(afterTwice))")
    }

    // One class ID cached in two entitled clubs (39 and 200) at different times: CLI and MCP refuse before any private request.
    do {
        let dir = ctx.scratch("l7-twin-clubs"), kcC = ctx.keychain("l7-twin-clubs"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock(), pub = mockPublicClient(store: st)
        try loginSeed(st, memberA, kcC, [])
        try st.seedSnapshot(clubSnapshot([openSlot.date: [row(871, openSlot.date, openSlot.time, "Twin")]], clubId: 39))
        try st.seedSnapshot(clubSnapshot([farSlot.date: [row(871, farSlot.date, farSlot.time, "Twin")]], clubId: 200))
        let before = mock.count
        let cli = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 871, isCancel: false, late: false, store: st, keychain: kcC, client: pub, bookingClient: mock.client) }
        let mcp = try toolResult(await MCPServer.handleLine("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"book_class\",\"arguments\":{\"class_id\":871}}}",
                                                            store: st, keychain: kcC, client: pub, bookingClient: mock.client))
        try assertTrue(cli.contains("multiple club definitions") && mcp.isError && mcp.text.contains("multiple club definitions") && mock.count == before,
                       "a class ID cached in clubs 39 and 200 is refused by the CLI and MCP with 0 private requests (\(cli))")
    }

    // Keychain warnings survive: an expiry of a replaced session (.superseded), a menu sign-out refused by an account
    // switch, and a sign-out that also fails its cache cleanup (both messages shown).
    do {
        let failRestore = Locked(false)
        let hooks = KeychainStore.Hooks(getInteractionAllowed: { (0, true) }, setInteractionAllowed: { allowed in
            var fail = false
            if allowed { failRestore.mutate { fail = $0; $0 = false } }
            return fail ? -25308 : 0
        })
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l7-expiry-warning")), kcE = ctx.keychain("l7-expiry-warning", hooks: hooks)
        try loginSeed(st, memberA, kcE, [])
        failRestore.value = true
        let expiry = st.expireSession(for: memberB, keychain: kcE)
        try assertTrue(expiryKind(expiry) == "superseded" && expiry.warning == restoreWarning && expiry.summary.contains(restoreWarning.localizedDescription),
                       "expireSession .superseded carries and names the restore warning (\(expiry.summary))")

        let switched = try ctx.freshVM("l7-signout-switched", hooks: hooks)
        await signIn(switched.vm)
        try SharedStateStore(primaryDirectory: switched.dir).commitLogin(memberB, keychain: switched.kc)
        failRestore.value = true
        switched.vm.signOut()
        let refusedBanner = switched.vm.bannerMessage ?? ""
        try assertTrue(refusedBanner.contains("nothing was removed") && refusedBanner.contains(restoreWarning.localizedDescription) && switched.vm.bannerIsError
                       && (try switched.kc.readSession())?.token == "tok_B", "a refused menu sign-out names the restore warning (\(refusedBanner))")

        let both = try ctx.freshVM("l7-signout-both", hooks: hooks, mirror: true)
        await signIn(both.vm)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: both.mirror!.path)
        failRestore.value = true
        both.vm.signOut()
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: both.mirror!.path)
        let bothBanner = both.vm.bannerMessage ?? ""
        try assertTrue(both.vm.memberSession == nil && bothBanner.contains("clearing cached bookings failed") && bothBanner.contains(restoreWarning.localizedDescription),
                       "a sign-out with a cache error and a restore warning shows both (\(bothBanner))")
    }

    // A deterministic clock in each occurrence of London's repeated autumn hour (2026-10-25 01:15 BST, then 01:15 GMT): a
    // booking 2h00m later is a late cancel (confirmation needed), one 3h00m01s later is not.
    do {
        try assertTrue(LondonCalendar.resolveLondonWallTime(dateIso: "2026-10-25", hhmm: "01:15") == .ambiguousRepeatedHour, "01:15 on 2026-10-25 is the repeated hour")
        for (label, stamp) in [("BST +01:00", "2026-10-25T00:15:00Z"), ("GMT +00:00", "2026-10-25T01:15:00Z")] {
            let fixedNow = ISO8601DateFormatter().date(from: stamp)!, late = slot(2 * 3600, from: fixedNow)
            let bookings = BookingsSnapshot(ownerKey: memberA.ownerKey!, bookings: [activeBooking(611, isoUTC(late.start)), activeBooking(612, isoUTC(fixedNow.addingTimeInterval(10_801)))], syncedAt: fixedNow)
            func decide(_ id: Int, _ confirmed: Bool) throws -> BookingAuthorization.CancelDecision {
                try BookingAuthorization.authorizeCancellation(classId: id, bookings: bookings, confirmedLate: confirmed, now: fixedNow) { nil }
            }
            let decisions = [try decide(611, false), try decide(611, true), try decide(612, false)]
            try assertTrue(late.start.timeIntervalSince(fixedNow) == 7200 && decisions == [.needsLateConfirmation, .authorized(lateBooking: true), .authorized(lateBooking: false)],
                           "\(label): 2h00m before start needs the late confirmation; 3h00m01s does not")
        }
    }

    // Snapshot rows: one ID on two dates with different values is offered on neither date; the valid row stays.
    do {
        let d2 = LondonCalendar.addDays(to: todayIso, days: 1)!
        let snap = clubSnapshot([todayIso: [row(851, todayIso, "09:00", "X")], d2: [row(851, d2, "09:00", "X"), row(852, d2, "10:00", "OK")]])
        try assertTrue(snap.classes(for: todayIso).isEmpty && snap.classes(for: d2).map(\.id) == [852] && snap.session(id: 851) == nil && snap.session(id: 852) != nil,
                       "a class ID repeated on two dates with different values is never offered; only the valid row is")
    }

    // The undated timetable query shared by CLI `timetable` and MCP `get_timetable`: the clock crosses London midnight while
    // the fresh cache only holds yesterday, so the new day is fetched (1 public request) and its classes are listed.
    do {
        let yesterday = LondonCalendar.addDays(to: todayIso, days: -1)!, st = SharedStateStore(primaryDirectory: ctx.scratch("l7-midnight"))
        try st.seedSnapshot(clubSnapshot([yesterday: [row(861, yesterday, "10:00", "Yesterday Ride")]]))
        MockHTTPBox.shared.set(39, body: timetableHTML([Fx(id: 862, slot: at(todayIso, "23:00"), title: "After Midnight")], emptyDays: (0...3).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) }))
        let before = MockHTTPBox.shared.count(39), clock = [at(yesterday, "23:59").start.addingTimeInterval(50), at(todayIso, "00:00").start.addingTimeInterval(10)]
        let reads = Locked(0)
        let result = try await TertiaCLI.queryTimetable(clubId: 39, date: nil, period: nil, search: nil, refresh: false, store: st, client: mockPublicClient(store: st)) { @Sendable in
            var n = 0; reads.mutate { n = $0; $0 += 1 }; return clock[min(n, 1)]
        }
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(result.date == todayIso && result.classes.map(\.id) == [862] && MockHTTPBox.shared.count(39) == before + 1,
                       "an undated query crossing midnight fetches and lists the new day (\(result.date), \(result.classes.map(\.id)))")
    }

    // A pending widget fetch (high request number, older start) that finishes after a newer mirrored host rename keeps the
    // host's newer club name and short code.
    do {
        let dir = ctx.scratch("l7-meta"), mdir = ctx.scratch("l7-meta-widget"), day = [todayIso: [ClassSession]()]
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), widget = SharedStateStore(primaryDirectory: mdir)
        let pendingStart = Date().addingTimeInterval(-300), renameAt = Date().addingTimeInterval(-60)
        _ = try host.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf Riverside", clubShortCode: "CWR", fetchedDays: day, fetchedRange: [todayIso],
                                          requestSeq: 5, syncedAt: renameAt)
        try host.repairSnapshotMirrorIfNeeded(clubId: 39)
        _ = try widget.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: day, fetchedRange: [todayIso],
                                            requestSeq: 9_000_000_000_000_000, syncedAt: pendingStart)
        let kept = widget.loadSnapshot(clubId: 39)
        try assertTrue(kept?.clubName == "Canary Wharf Riverside" && kept?.clubShortCode == "CWR", "a late pending widget fetch never undoes a newer host rename (\(kept?.clubName ?? "nil"))")
    }

    // A <script src> body and a <template> script, each with empty declarations, before the real script never hide its classes.
    for (label, decoy) in [("script src", "<script src=\"app.js\">let clubs=[];let timetable={};</script>"),
                           ("template", "<template><script>let clubs=[];let timetable={};</script></template>")] {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l7-decoy"))
        MockHTTPBox.shared.set(39, body: decoy + timetableHTML([Fx(id: 895, slot: openSlot, title: "Decoy Guard")], emptyDays: [openSlot.date]))
        let snap = try await mockPublicClient(store: st).fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true)
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(snap.session(id: 895) != nil && st.loadSnapshot(clubId: 39)?.session(id: 895) != nil, "classes after a \(label) decoy are parsed and cached")
    }

    // Menu empty-state copy at 20:00 London: not loaded, an empty day, a day whose classes all started, and a filter that
    // hides a class still to come.
    do {
        let f = try ctx.freshVM("l7-empty-copy"), eight = at(todayIso, "20:00").start
        func message(_ snap: TimetableSnapshot, search: String = "") -> String { f.vm.snapshot = snap; f.vm.preferences.searchQuery = search; return f.vm.emptyScheduleMessage(now: eight) }
        let copies = [message(clubSnapshot([:])), message(clubSnapshot([todayIso: []])), message(clubSnapshot([todayIso: [row(871, todayIso, "07:00")]])),
                      message(clubSnapshot([todayIso: [row(871, todayIso, "07:00"), row(872, todayIso, "21:00")]]), search: "zzz"),
                      message(clubSnapshot([todayIso: [row(871, todayIso, "07:00")]]), search: "zzz")]
        try assertEqual(copies, ["Schedule not loaded for this date.", "No classes scheduled for this date.", "No more classes today.", "No classes match this filter.", "No more classes today."],
                        "the menu's empty-state copy says why the list is empty")
    }

    // Widget: an unmatched search with one unfiltered class left at 20:30 adds that start to the timeline, where the text
    // turns from "No classes match filter" into "No more classes today".
    do {
        let eight = at(todayIso, "20:00").start, half = at(todayIso, "20:30").start
        let snap = clubSnapshot([todayIso: [row(881, todayIso, "07:00", "Ride"), row(882, todayIso, "20:30", "Flow")]])
        var prefs = TertiaPreferences(); prefs.searchQuery = "zzz"
        let texts = [eight, half].map { widgetEmptyText(snapshot: snap, preferences: prefs, now: $0, clubEmpty: "No more classes today") }
        try assertTrue(widgetTimelineDates(snapshot: snap, preferences: prefs, now: eight) == [eight, half] && texts == ["No classes match filter", "No more classes today"],
                       "the widget timeline includes the last unfiltered start, when its empty text changes (\(texts))")
    }

    // The README preview scene never pairs a thin live day with the 06:00 clock: an empty or 2-row live day falls back to
    // the 6-row sample day at 06:00, with a booked row that is shown and has not started.
    for rows in [[], [row(891, todayIso, "23:00"), row(892, todayIso, "23:30")]] {
        let scene = SampleData.previewScene(live: clubSnapshot([todayIso: rows]), now: at(todayIso, "07:00").start)
        let shown = widgetUpcomingSessions(snapshot: scene.snapshot, preferences: TertiaPreferences(), now: scene.now)
        try assertTrue(LondonCalendar.formatSyncTime(scene.now) == "06:00" && shown.count == 6 && scene.bookedRow.map { shown.contains($0) && scene.snapshot.session(id: $0.id) == $0 } == true,
                       "a \(rows.count)-row live day falls back to the 6-row sample at 06:00 with a shown booked row")
    }

    // The shipped binary's MCP loop: a line that is not UTF-8 answers -32700 with id null, then ping answers id 7.
    do {
        let rawAppBin = ProcessInfo.processInfo.environment["TERTIA_APP_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "dist/Tertia.app/Contents/MacOS/Tertia"
        let appBin = rawAppBin.hasPrefix("/") ? rawAppBin : root.appendingPathComponent(rawAppBin).path
        let input = ctx.scratch("l7-mcp-input"), home = ctx.scratch("l7-mcp-home")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try Data([0x7B, 0xFF, 0xFE, 0x7D, 0x0A] + Array("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n".utf8)).write(to: input)
        let res = try runSubprocess(appBin, args: ["mcp"], env: ["HOME": home.path, "CFFIXED_USER_HOME": home.path], stdin: try FileHandle(forReadingFrom: input), timeoutSeconds: 10)
        let lines = res.stdout.split(separator: "\n").map(String.init)
        let first = try decodeJSON(lines.first), second = try decodeJSON(lines.last)
        try assertTrue(res.status == 0 && !res.timedOut && lines.count == 2 && (first["error"] as? [String: Any])?["code"] as? Int == -32700 && first["id"] is NSNull && second["id"] as? Int == 7 && second["error"] == nil,
                       "the shipped `mcp` answers malformed UTF-8 with -32700 (id null), then ping with id 7 (\(lines))")
    }

    // curl output caps: a child that ignores SIGTERM and floods stdout or stderr fails with the size error in under 1.5 s
    // and is reaped. The config written is the one for the request the gate hands over (rebuilt only when it changed).
    for stream in ["stdout", "stderr"] {
        let pidFile = ctx.scratch("l7-curl-pid-\(stream)"), began = Date()
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; cat >/dev/null; head -c 300000 /dev/zero \(stream == "stderr" ? ">&2" : ""); exec /bin/sleep 10"
        let thrown = denial {
            _ = try MobileBookingClient.runCurlSync(MobileRequest(method: "GET", url: "http://127.0.0.1:9/", headers: []),
                                                    hooks: .init(executablePath: "/bin/sh", arguments: ["-c", script], timeoutSeconds: 8, maxOutputBytes: 100_000))
        }
        let elapsed = Date().timeIntervalSince(began), pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try assertTrue(thrown.contains("exceeded maximum size (100000 bytes)") && elapsed < 1.5 && pid.map { kill($0, 0) != 0 } == true,
                       "a SIGTERM-ignoring child flooding \(stream) fails in \(String(format: "%.2f", elapsed))s and is reaped (\(thrown))")
    }
    do {
        let capture = ctx.scratch("l7-curl-config")
        let original = MobileRequest(method: "PUT", url: "http://127.0.0.1:9/api/v2/member/classes/cancel_booking", headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
                                     body: "{\"classId\":601,\"lateBooking\":false}")
        let changed = MobileRequest(method: original.method, url: original.url, headers: original.headers, body: "{\"classId\":601,\"lateBooking\":true}")
        for handed in [original, changed] {
            _ = try MobileBookingClient.runCurlSync(original, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", "cat > '\(capture.path)'; printf '\\n200'"], timeoutSeconds: 5),
                                                    gate: { _, handoff in try handoff(handed) })
            try assertTrue(try String(contentsOf: capture, encoding: .utf8) == MobileBookingClient.buildCurlConfig(handed),
                           "curl receives the config of the handed-over request (\(handed.body ?? ""))")
        }
    }

    // Scripts: TERM to test.sh stops the hanging tool and its background child through run-watched and removes the
    // private build folder; publish.py rejects non-finite or negative lock timeouts at once; print-test-python accepts a
    // TERTIA_TEST_PYTHON wrapper.
    do {
        let shRoot = ctx.scratch("l7-testsh"), probe = shRoot.appendingPathComponent("probe")
        for dir in ["Scripts", "probe"] { try fm.createDirectory(at: shRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Scripts/test.sh", "Scripts/publish.py"] { try fm.copyItem(at: root.appendingPathComponent(path), to: shRoot.appendingPathComponent(path)) }
        let tool = shRoot.appendingPathComponent("Scripts/package_app.sh")
        try "#!/bin/bash\necho \"$TERTIA_BUILD_DIR\" > \"$PROBE/build-dir\"\n/bin/sleep 30 &\necho $! > \"$PROBE/bg.pid\"\necho $$ > \"$PROBE/tool.pid\"\nexec /bin/sleep 30\n"
            .write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let proc = Process(), exited = DispatchSemaphore(value: 0)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", "setpgrp(0, 0); exec @ARGV", "/bin/bash", shRoot.appendingPathComponent("Scripts/test.sh").path]
        proc.environment = ProcessInfo.processInfo.environment.merging(["PROBE": probe.path]) { $1 }
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { _ in exited.signal() }
        try proc.run()
        let group = proc.processIdentifier
        defer { if proc.isRunning { kill(-group, SIGKILL) } }
        func pid(_ name: String) -> pid_t? { (try? String(contentsOf: probe.appendingPathComponent(name), encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        for _ in 0..<1000 where pid("tool.pid") == nil || pid("bg.pid") == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let buildDir = (try? String(contentsOf: probe.appendingPathComponent("build-dir"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let watchedPids = [pid("tool.pid"), pid("bg.pid")].compactMap { $0 }
        kill(-group, SIGTERM)
        let stopped = await waitFor(exited, seconds: 6)
        for _ in 0..<200 where watchedPids.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        try assertTrue(stopped && proc.terminationStatus != 0 && watchedPids.count == 2 && watchedPids.allSatisfy { kill($0, 0) != 0 } && !buildDir.isEmpty && !fm.fileExists(atPath: buildDir),
                       "TERM to test.sh stops the hanging tool and its background child and removes \(buildDir)")
        let publish = root.appendingPathComponent("Scripts/publish.py").path, lockFile = ctx.scratch("l7-lock").path
        for bad in ["nan", "inf", "-1"] {
            let began = Date()
            let res = try runSubprocess("/usr/bin/python3", args: ["-I", publish, "lock", "--timeout", bad, lockFile, "/usr/bin/true"], timeoutSeconds: 5)
            try assertTrue(res.status == 1 && res.stderr.contains("finite number") && Date().timeIntervalSince(began) < 2, "publish.py lock --timeout \(bad) fails at once")
        }
        let wrapper = ctx.scratch("l7-python-wrapper"), python = try testPython(root: root)
        try "#!/bin/sh\nexec '\(python)' \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let picked = try runSubprocess("/usr/bin/python3", args: ["-I", publish, "print-test-python"], env: ["TERTIA_TEST_PYTHON": wrapper.path], timeoutSeconds: 10)
        try assertTrue(picked.status == 0 && !picked.timedOut && picked.stdout == wrapper.path + "\n", "print-test-python returns a qualifying TERTIA_TEST_PYTHON wrapper (\(picked.stderr))")
        let standalone = ProcessInfo.processInfo.environment.merging(["TERTIA_RESOLVED_PYTHON": "", "TERTIA_TEST_PYTHON": wrapper.path]) { $1 }
        try assertEqual(try testPython(root: root, environment: standalone), wrapper.path, "a standalone run selects TERTIA_TEST_PYTHON through print-test-python")
    }

    // Makefile: custom TERTIA_BUILD_DIR, TERTIA_DIST_APP, and INSTALL_APP are the paths used; a failed lsregister or
    // pluginkit names its step and `make register`, and after `install` says the bundle was already replaced.
    do {
        func make(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
            try runSubprocess("/usr/bin/make", args: ["-C", root.path, "--no-print-directory"] + args, timeoutSeconds: 15)
        }
        let paths = ["INSTALL_APP=/x/Inst.app", "TERTIA_DIST_APP=/x/Dist.app", "TERTIA_BUILD_DIR=/x/build"]
        let dry = try make(["-n", "run", "cli"] + paths), install = try make(["-n", "install", "LSREGISTER=/usr/bin/false"] + paths)
        try assertTrue(dry.status == 0 && !dry.timedOut && dry.stdout.contains("open \"/x/Inst.app\" || open \"/x/Dist.app\"") && dry.stdout.contains("TERTIA_BUILD_DIR=\"/x/build\" ./Scripts/build.sh")
                       && dry.stdout.contains("\"/x/build/TertiaApp\" timetable --club 39") && install.stdout.contains("cp -R \"/x/Dist.app\"") && install.stdout.contains("swap")
                       && install.stdout.contains("Installed /x/Inst.app (bundle replaced), but registration step 'lsregister' failed; to retry, run: make register INSTALL_APP='/x/Inst.app'"),
                       "make run/cli/install use the custom paths, and install's registration failure names the committed replacement")
        let target = ctx.scratch("l7-register").appendingPathComponent("Tertia.app").path
        for (tools, step) in [(["LSREGISTER=/usr/bin/false"], "lsregister"), (["LSREGISTER=/usr/bin/true", "PLUGINKIT=/usr/bin/false"], "pluginkit")] {
            let res = try make(["register", "INSTALL_APP=\(target)"] + tools)
            try assertTrue(res.status != 0 && res.stderr.contains("For \(target), registration step '\(step)' failed; to retry, run: make register INSTALL_APP='\(target)'"),
                           "make register names the failed \(step) step (\(res.stderr))")
        }
    }
}

/// Loop 8 regressions: one block per fix, each checking the observable outcome (requests sent, files, and what each
/// surface shows).
@MainActor func loop8(_ ctx: TestContext) async throws {
    let fm = ctx.fm, root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let publish = root.appendingPathComponent("Scripts/publish.py").path
    let extra = Club(id: 250, name: "Zeta Extra", shortCode: "ZX"), ambiguous = "conflicting or multiple club definitions"
    let stale = ScheduleViewModel.staleIntentMessage, restoreWarning = KeychainError.interactionRestoreFailed(-25308).localizedDescription
    func snapshot(_ days: [String: [ClassSession]], clubId: Int = 39) -> TimetableSnapshot { clubSnapshot(days, clubId: clubId, clubs: [canary, woodWharf, extra]) }
    /// Every text item of a tools/call result, joined (a note such as a Keychain warning is its own item).
    func toolTexts(_ line: String?) throws -> String {
        ((try decodeJSON(line)["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    MockHTTPBox.shared.set(39, body: page39)

    // Harness: a past fixture inside the repeated autumn hour steps backward out of it (2026-10-25 02:30 GMT, one hour back).
    do {
        let fixed = ISO8601DateFormatter().date(from: "2026-10-25T02:30:00Z")!, past = slot(-3600, from: fixed)
        try assertTrue(past.start < fixed && LondonCalendar.resolveLondonWallTime(dateIso: past.date, hhmm: past.time) == .exact(past.start),
                       "slot(-3600) at 2026-10-25T02:30Z stays in the past with one exact start (\(past.date) \(past.time))")
    }

    // Booking identity parity: two entitled clubs sharing a class ID, or one club with two conflicting rows for it, is
    // refused by the menu, the CLI, and MCP with 0 private requests.
    let twinA = row(801, openSlot.date, openSlot.time, "Twin"), twinB = row(801, openSlot.date, openSlot.time, "Twin Other")
    for (label, club200) in [("one row in each of clubs 39 and 200", [twinA]), ("one row in club 39 and two conflicting rows in club 200", [twinA, twinB])] {
        let f = try ctx.freshVM("l8-identity", seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [])
            try st.seedSnapshot(snapshot([openSlot.date: [twinA]]))
            try st.seedSnapshot(snapshot([openSlot.date: club200], clubId: 200))
        })
        let pub = mockPublicClient(store: f.store), before = f.mock.count
        let cli = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 801, isCancel: false, late: false, store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client) }
        let mcp = try toolResult(await MCPServer.handleLine(bookLine("801"), store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client))
        try await pressDisabled(f.vm, twinA)
        try assertTrue(cli.contains(ambiguous) && mcp.isError && mcp.text.contains(ambiguous) && (f.vm.bannerMessage ?? "").contains(ambiguous) && f.mock.count == before,
                       "\(label): menu, CLI, and MCP refuse the booking with 0 private requests (\(cli) | \(f.vm.bannerMessage ?? "nil"))")
    }

    // The 3-hour cancel guard reads every active record: +4h and +2h records for one class are refused in both orders,
    // repeated records of one instant are accepted.
    do {
        let now = Date(timeIntervalSince1970: 1_800_000_000), four = isoUTC(now.addingTimeInterval(4 * 3600)), two = isoUTC(now.addingTimeInterval(2 * 3600))
        func decide(_ stamps: [String]) -> String {
            denial { _ = try BookingAuthorization.authorizeCancellation(classId: 701, bookings: BookingsSnapshot(ownerKey: "id:7", bookings: stamps.map { activeBooking(701, $0) }, syncedAt: now),
                                                                         confirmedLate: false, now: now) { nil } }
        }
        try assertTrue(decide([four, two]).contains("Conflicting") && decide([two, four]).contains("Conflicting") && decide([four, four]) == "",
                       "conflicting active records refuse in both orders; repeated records of one instant are accepted")
    }

    // A class ID colliding across entitled public timetables: a cancellation dated by the member's own booking succeeds
    // (menu and CLI); one with an empty start stamp is refused before dispatch.
    for surface in ["cli", "menu"] {
        for stamp in [isoUTC(farSlot.start), ""] {
            let twin = row(811, farSlot.date, farSlot.time, "Twin Cancel")
            let f = try ctx.freshVM("l8-collide-\(surface)", seed: { st, kc, _, _ in
                try loginSeed(st, memberA, kc, [activeBooking(811, stamp)])
                for club in [39, 200] { try st.seedSnapshot(snapshot([farSlot.date: [twin]], clubId: club)) }
            })
            let before = f.mock.count
            var message = ""
            if surface == "cli" {
                message = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 811, isCancel: true, late: false, store: f.store, keychain: f.kc,
                                                                                     client: mockPublicClient(store: f.store), bookingClient: f.mock.client) }
            } else {
                if stamp.isEmpty { try await pressDisabled(f.vm, twin) } else { try await click(f.vm, twin) }
                message = f.vm.bannerIsError ? f.vm.bannerMessage ?? "" : ""
            }
            let sent = f.mock.actions(after: before).map(\.body)
            if stamp.isEmpty {
                try assertTrue(message.contains(ambiguous) && f.mock.count == before, "\(surface): an undated cancel of a colliding ID is refused before dispatch (\(message))")
            } else {
                try assertTrue(message.isEmpty && sent == ["{\"classId\":811,\"lateBooking\":false}"], "\(surface): a cancel dated by the booking succeeds despite the collision (\(message))")
            }
        }
    }

    // A menu row rescheduled (two open times) or retitled after its button was drawn: the old Book callback sends 0
    // private requests, refused under the lock (disk changed) and then before it (the reloaded menu shows the new row).
    let early = slot(5 * 3600), later = slot(7 * 3600), drawn = row(821, early.date, early.time, "Ride")
    for (label, moved) in [("rescheduled", row(821, later.date, later.time, "Ride")), ("retitled", row(821, early.date, early.time, "Ride II"))] {
        let f = try ctx.freshVM("l8-moved", seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, []); try st.seedSnapshot(snapshot([early.date: [drawn]])) })
        f.vm.selectedDate = early.date
        guard let book = f.vm.classAction(for: drawn) else { throw AssertionFailure(description: "FAIL: \(label): the drawn row has no Book action") }
        try f.store.seedSnapshot(snapshot([moved.date: [moved]]))
        let before = f.mock.count
        await book()
        let underLock = f.vm.bannerMessage == stale && f.vm.snapshot?.session(id: 821) == moved
        f.vm.bannerMessage = nil
        await book()
        try assertTrue(underLock && f.vm.bannerMessage == stale && f.mock.count == before, "\(label) row: the old Book callback sends 0 private requests and reloads the new row")
    }

    // A one-time Keychain read failure sends 0 private requests and keeps the cache valid, whether it hits the preflight
    // gate (before any authorize callback) or the launch gate (after the preflight authorize passed).
    for stage in ["preflight", "launch"] {
        let failNext = Locked(false), calls = Locked(0)
        let hooks = KeychainStore.Hooks(getInteractionAllowed: { var fail = false; failNext.mutate { fail = $0; $0 = false }; return fail ? (-50, true) : (0, true) })
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-\(stage)")), kcP = ctx.keychain("l8-\(stage)", hooks: hooks), mock = MobileMock()
        try loginSeed(st, memberA, kcP, [activeBooking(502, isoUTC(lateSlot.start))])
        failNext.value = stage == "preflight" // the next Keychain read is the preflight gate's
        let thrown = await denialAsync {
            _ = try await mock.client.mutateAndSync(classId: 501, isCancel: false, session: memberA, store: st, keychain: kcP) { _, _, _ in
                var n = 0; calls.mutate { $0 += 1; n = $0 }
                if n == 1 { failNext.value = true } // the next Keychain read is the launch gate's
                return false
            }
        }
        try assertTrue(!thrown.isEmpty && calls.value == (stage == "preflight" ? 0 : 1) && mock.count == 0 && st.loadBookings(for: memberA)?.bookedIds == [502],
                       "a Keychain read failure at the \(stage) gate runs \(calls.value) authorize callbacks, sends 0 private requests, and keeps the cached bookings valid (\(thrown))")
    }

    // curl never sees the member's password or a TLS key log path.
    do {
        let env = MobileBookingClient.sanitizedCurlEnvironment(["PATH": "/usr/bin", "SSLKEYLOGFILE": "/tmp/keys", "sslkeylogfile": "/tmp/keys2", "TERTIA_PASSWORD": "pw"])
        try assertTrue(env["SSLKEYLOGFILE"] == nil && env["sslkeylogfile"] == nil && env["TERTIA_PASSWORD"] == nil && env["PATH"] == "/usr/bin",
                       "sanitizedCurlEnvironment strips SSLKEYLOGFILE (any case) and TERTIA_PASSWORD")
    }

    // MCP class_id accepts only exact integers.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-mcp-int")), kcM = ctx.keychain("l8-mcp-int"), mock = MobileMock(), pub = mockPublicClient(store: st)
        for (raw, rejected) in [("9007199254740992.1", true), ("1.000000000000000000001", true), ("1.5", true), ("18446744073709551615", true), ("501", false), ("9007199254740993", false)] {
            let code = try errorCode(await MCPServer.handleLine(bookLine(raw), store: st, keychain: kcM, client: pub, bookingClient: mock.client))
            try assertTrue((code == -32602) == rejected && mock.count == 0, "MCP class_id \(raw) is \(rejected ? "rejected as -32602" : "accepted for validation") (code \(code.map(String.init) ?? "none"))")
        }
    }

    // HTTP 403: an auth failure in any recognized error field expires the session; a membership-only denial keeps it.
    for (body, expires) in [("{\"errors\":{\"booking\":[\"Membership tier restriction\"]},\"message\":\"Session expired\"}", true),
                            ("{\"errors\":{\"booking\":[\"Membership tier restriction\"]}}", false)] {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-403")), kc403 = ctx.keychain("l8-403")
        try loginSeed(st, memberA, kc403, [])
        let client = MobileBookingClient { req in try MobileBookingClient.performHandoff(req) { _ in }; return (403, Data(body.utf8)) }
        var thrown: Error?
        do { _ = try await TertiaCLI.memberBookings(refresh: true, store: st, keychain: kc403, bookingClient: client) } catch { thrown = error }
        let stored = try kc403.readSession()
        try assertTrue(thrown != nil && BookingClientError.isUnauthorized(thrown!) == expires && (expires ? stored == nil : stored == memberA),
                       "a 403 \(expires ? "naming an expired session deletes the Keychain session" : "for membership only keeps it") (\(thrown?.localizedDescription ?? "no error"))")
    }

    // `login --password-stdin` with bytes that are not UTF-8 fails locally: exit 1 and 0 login requests.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-pw")), kcPw = ctx.keychain("l8-pw"), mock = MobileMock(), input = ctx.scratch("l8-pw-input")
        try Data([0xFF, 0xFE]).write(to: input)
        let saved = dup(STDIN_FILENO), fd = Darwin.open(input.path, O_RDONLY)
        guard saved >= 0, fd >= 0, dup2(fd, STDIN_FILENO) >= 0 else { throw AssertionFailure(description: "FAIL: stdin redirection setup") }
        close(fd)
        let res = try await captureOutput(fd: STDERR_FILENO) {
            await TertiaCLI.run(args: ["login", "--email", "a@example.com", "--password-stdin"], store: st, keychain: kcPw, client: mockPublicClient(store: st), bookingClient: mock.client)
        }
        guard dup2(saved, STDIN_FILENO) >= 0 else { throw AssertionFailure(description: "FAIL: stdin restore") }
        close(saved)
        try assertTrue(res.code == 1 && res.out.contains("not valid UTF-8") && mock.logins == 0, "invalid UTF-8 on --password-stdin exits 1 with 0 login requests (\(res.out))")
    }

    // A widget mirror whose bookings.json cannot be replaced (old same-owner IDs inside) shows 0 booked badges until a
    // repair succeeds, whether the failed copy comes from the launch repair or from a bookings sync.
    for path in ["repair", "sync"] {
        let dir = ctx.scratch("l8-mirror-\(path)"), mdir = ctx.scratch("l8-mirror-\(path)-widget"), kcF = ctx.keychain("l8-mirror-\(path)")
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), widget = SharedStateStore(primaryDirectory: mdir), mirrored = mdir.appendingPathComponent("bookings.json")
        let newer = [activeBooking(502, isoUTC(lateSlot.start))]
        try loginSeed(st, memberA, kcF, [activeBooking(501, isoUTC(openSlot.start))])
        let seeded = widget.readConsistentWidgetState().bookedIds
        if path == "repair" { try syncSeed(SharedStateStore(primaryDirectory: dir), memberA, kcF, newer) } // the mirror still holds [501]
        try immutable(mirrored, true)
        let failed = path == "repair" ? Result { try st.reconcileAccountMirror(for: memberA, keychain: kcF) }.error
            : (try? st.commitSyncedBookings(newer, for: memberA, started: try st.beginBookingsSync(for: memberA, keychain: kcF), keychain: kcF))?.mirrorError
        let during = widget.readConsistentWidgetState().bookedIds
        try immutable(mirrored, false)
        if path == "repair" { _ = try st.reconcileAccountMirror(for: memberA, keychain: kcF) } else { try syncSeed(st, memberA, kcF, newer) }
        try assertTrue(seeded == [501] && failed != nil && during.isEmpty && widget.readConsistentWidgetState().bookedIds == [502],
                       "\(path): a failed mirror bookings copy shows 0 widget badges (not the old [501]) until the repair writes [502] (\(during))")
    }

    // Host account and preferences reach the widget mirror as one step: a widget read started while the host is paused
    // between them waits, so it never pairs the new booked IDs with the old club.
    do {
        let dir = ctx.scratch("l8-coordinated"), mdir = ctx.scratch("l8-coordinated-widget"), kcC = ctx.keychain("l8-coordinated")
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), primaryOnly = SharedStateStore(primaryDirectory: dir)
        try loginSeed(host, memberA, kcC, [activeBooking(501, isoUTC(openSlot.start))])
        _ = try host.updatePreferences { $0.clubId = 39; $0.clubName = "Canary Wharf"; $0.clubShortCode = "CANARY" }
        try syncSeed(primaryOnly, memberA, kcC, [activeBooking(601, isoUTC(farSlot.start))])
        _ = try primaryOnly.updatePreferences { $0.clubId = 200; $0.clubName = "Wood Wharf"; $0.clubShortCode = "WW" }
        let widget = SharedStateStore(primaryDirectory: mdir, lockTimeout: 3), read = Locked<(Int, Set<Int>)?>(nil), done = DispatchSemaphore(value: 0), waited = Locked(false)
        let paused = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir, betweenAccountAndPreferences: {
            DispatchQueue.global().async { let state = widget.readConsistentWidgetState(); read.value = (state.preferences.clubId, state.bookedIds); done.signal() }
            Thread.sleep(forTimeInterval: 0.3)
            waited.value = done.wait(timeout: .now()) == .timedOut
        })
        _ = try paused.reconcileAccountMirror(for: memberA, keychain: kcC)
        let finished = await waitFor(done)
        try assertTrue(finished && waited.value && read.value?.0 == 200 && read.value?.1 == [601],
                       "a widget read during the paused host publication waits and then sees club 200 with [601] (\(String(describing: read.value)))")
    }

    // A signed-out menu with cached extra club 250 shows it right after signing in to a member entitled only to 250.
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-catalog")), kcZ = ctx.keychain("l8-catalog")
        try st.seedSnapshot(snapshot([todayIso: []], clubId: 250))
        let only250 = MobileBookingClient { req in
            try MobileBookingClient.performHandoff(req) { _ in }
            if req.url.contains("/auth/login") {
                return (200, Data("{\"token\":\"tok_Z\",\"id\":25,\"name\":\"Zed\",\"email\":\"z@example.com\",\"homeClubId\":250,\"homeClubName\":\"Zeta Extra\",\"expiresAt\":\"\",\"clubs\":[{\"id\":250,\"name\":\"Zeta Extra\"}]}".utf8))
            }
            return (200, Data(classesJSON([]).utf8))
        }
        let vm = ScheduleViewModel(store: st, keychain: kcZ, client: mockPublicClient(store: st), bookingClient: only250)
        let signedOut = vm.availableClubs.map(\.id)
        await signIn(vm, "z@example.com")
        try assertTrue(signedOut.count == 17 && !signedOut.contains(250) && vm.memberSession?.token == "tok_Z" && vm.availableClubs.map(\.id) == [250] && vm.preferences.clubId == 250,
                       "signing in adopts the cached catalog: the picker offers extra club 250 at once (\(vm.availableClubs.map(\.id)))")
    }

    // An unreadable Keychain item with extra club 250 saved: the menu shows signed-out club 39 while 250 stays on disk.
    // Signing in then loses the old credential (.previousSessionLost): host and widget clubs return to 39, the form is
    // cleared like a sign-out, and other surfaces are notified.
    do {
        let service = ctx.keychainService("l8-lost"), calls = Locked(0), armed = Locked(false)
        let kcL = KeychainStore(service: service, account: "verify", hooks: .init(getInteractionAllowed: {
            var n = 0
            if armed.value { calls.mutate { $0 += 1; n = $0 } }
            return n == 5 ? (-50, true) : (0, true) // the 5th call after arming guards SecItemAdd, right after the unreadable item was deleted
        }))
        try seedForeignKeychainItem(service: service, account: "verify")
        let dir = ctx.scratch("l8-lost"), mdir = ctx.scratch("l8-lost-widget"), st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), mock = MobileMock()
        try st.seedSnapshot(snapshot([todayIso: []], clubId: 250))
        _ = try st.updatePreferences { $0.clubId = 250; $0.clubName = "Zeta Extra"; $0.clubShortCode = "ZX" }
        let notified = Locked(0)
        let vm = ScheduleViewModel(store: st, keychain: kcL, client: mockPublicClient(store: st), bookingClient: mock.client, onStateChanged: { notified.mutate { $0 += 1 } })
        try assertTrue(vm.memberSession == nil && vm.preferences.clubId == 39 && vm.availableClubs.count == 17 && st.loadPreferences().clubId == 250
                       && vm.bannerMessage == "App updated. Sign in again to reconnect Keychain.",
                       "an unreadable Keychain shows signed-out club 39 in the picker and keeps club 250 in preferences.json")
        armed.value = true
        let before = notified.value
        await signIn(vm)
        try assertTrue(vm.memberSession == nil && vm.emailInput.isEmpty && vm.passwordInput.isEmpty && vm.preferences.clubId == 39 && st.loadPreferences().clubId == 39
                       && SharedStateStore(primaryDirectory: mdir).loadPreferences().clubId == 39 && notified.value > before && vm.bannerIsError && mock.logins == 1,
                       "a lost previous credential resets host and widget clubs to 39, clears the form, and notifies (\(vm.bannerMessage ?? "nil"))")
    }

    // A Keychain UI-restore warning is reported once by CLI `clubs` and `set-club` (stderr) and by MCP `list_clubs` and
    // `set_widget_club`, and the normal output still appears.
    do {
        let hooks = KeychainStore.Hooks(getInteractionAllowed: { (0, true) }, setInteractionAllowed: { $0 ? -25308 : 0 })
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-warn")), kcW = ctx.keychain("l8-warn", hooks: hooks), mock = MobileMock(), pub = mockPublicClient(store: st)
        try loginSeed(st, memberA, kcW, [])
        func cli(_ args: [String]) async throws -> (code: Int32, out: String, err: String) {
            var out: (code: Int32, out: String) = (0, "")
            let err = try await captureOutput(fd: STDERR_FILENO) {
                out = try await captureOutput { await TertiaCLI.run(args: args, store: st, keychain: kcW, client: pub, bookingClient: mock.client) }
                return out.code
            }
            return (out.code, out.out, err.out)
        }
        func mcp(_ tool: String, _ args: String) async throws -> (isError: Bool, text: String) {
            var line: String?
            _ = try await captureOutput(fd: STDERR_FILENO) {
                line = await MCPServer.handleLine("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":\(args)}}", store: st, keychain: kcW, client: pub, bookingClient: mock.client)
                return 0
            }
            return (try toolResult(line).isError, try toolTexts(line))
        }
        func once(_ text: String) -> Bool { text.components(separatedBy: restoreWarning).count == 2 }
        let clubs = try await cli(["clubs"]), setClub = try await cli(["set-club", "39"])
        let listed = try await mcp("list_clubs", "{}"), selected = try await mcp("set_widget_club", "{\"club_id\":39}")
        try assertTrue(clubs.code == 0 && clubs.out.contains("Canary Wharf") && once(clubs.err) && setClub.code == 0 && setClub.out.contains("Widget club set to Canary Wharf") && once(setClub.err)
                       && !listed.isError && listed.text.contains("Wood Wharf") && once(listed.text) && !selected.isError && selected.text.contains("Widget club updated to Canary Wharf") && once(selected.text),
                       "the restore warning appears once on CLI clubs/set-club and MCP list_clubs/set_widget_club with their normal output (\(setClub.err))")
    }

    // Widget: at 23:40 with an unmatched search and a sole 00:10 class tomorrow, 00:10 is a timeline entry and shows
    // "No more classes today".
    do {
        let tomorrow = LondonCalendar.addDays(to: todayIso, days: 1)!, at2340 = at(todayIso, "23:40").start, at0010 = at(tomorrow, "00:10").start
        let snap = snapshot([todayIso: [], tomorrow: [row(841, tomorrow, "00:10", "Night Ride")]])
        var prefs = TertiaPreferences(); prefs.searchQuery = "zzz"
        try assertTrue(widgetTimelineDates(snapshot: snap, preferences: prefs, now: at2340).contains(at0010)
                       && widgetEmptyText(snapshot: snap, preferences: prefs, now: at0010, clubEmpty: "No more classes today") == "No more classes today",
                       "a filtered widget at 23:40 adds tomorrow's last unfiltered start (00:10), where it shows the no-more-classes text")
    }

    // The undated timetable query crossing midnight: a 00:05 class that starts during the second fetch (00:01 -> 00:06) is
    // not listed.
    do {
        let yesterday = LondonCalendar.addDays(to: todayIso, days: -1)!, st = SharedStateStore(primaryDirectory: ctx.scratch("l8-midnight"))
        try st.seedSnapshot(snapshot([yesterday: [row(851, yesterday, "10:00")]]))
        MockHTTPBox.shared.set(39, body: timetableHTML([Fx(id: 852, slot: at(todayIso, "00:05"), title: "Just Started"), Fx(id: 853, slot: at(todayIso, "23:00"), title: "Tonight")],
                                                       emptyDays: (0...3).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) }))
        let clock = [at(yesterday, "23:59").start.addingTimeInterval(50), at(todayIso, "00:01").start, at(todayIso, "00:06").start], reads = Locked(0)
        let result = try await TertiaCLI.queryTimetable(clubId: 39, date: nil, period: nil, search: nil, refresh: false, store: st, client: mockPublicClient(store: st)) { @Sendable in
            var n = 0; reads.mutate { n = $0; $0 += 1 }; return clock[min(n, 2)]
        }
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(result.date == todayIso && result.classes.map(\.id) == [853], "a class that started during the second fetch is not listed (\(result.classes.map(\.id)))")
    }

    // Snapshot merges: an equal-stamp host repair keeps the widget's own day revision, so an older pending widget fetch
    // cannot overwrite that day; in one store a higher request number that started 1s earlier replaces rows and names.
    do {
        let dir = ctx.scratch("l8-equal"), mdir = ctx.scratch("l8-equal-widget"), stamp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 120).rounded(.down))
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), widget = SharedStateStore(primaryDirectory: mdir)
        func merge(_ st: SharedStateStore, _ id: Int, seq: UInt64, at: Date, name: String = "Canary Wharf", short: String = "CANARY") throws {
            _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: name, clubShortCode: short, fetchedDays: [todayIso: [row(id, todayIso, "10:00")]],
                                            fetchedRange: [todayIso], requestSeq: seq, syncedAt: at)
        }
        try merge(widget, 861, seq: 100, at: stamp)
        try merge(host, 862, seq: 5, at: stamp)
        try merge(widget, 863, seq: 50, at: stamp)
        let kept = widget.loadSnapshot(clubId: 39)
        let same = SharedStateStore(primaryDirectory: ctx.scratch("l8-same-store"))
        try merge(same, 871, seq: 10, at: stamp)
        try merge(same, 872, seq: 11, at: stamp.addingTimeInterval(-1), name: "Canary Wharf Riverside", short: "CWR")
        let replaced = same.loadSnapshot(clubId: 39)
        try assertTrue(kept?.classes(for: todayIso).map(\.id) == [861] && kept?.dayRevision[todayIso] == 100
                       && replaced?.classes(for: todayIso).map(\.id) == [872] && replaced?.clubName == "Canary Wharf Riverside" && replaced?.clubShortCode == "CWR",
                       "equal-stamp repairs keep the widget day revision (\(kept?.classes(for: todayIso).map(\.id) ?? [])); a higher request number replaces rows and names")
    }

    // Parser: a <noscript> decoy and a regex literal naming the declarations never hide the real classes; one club ID with
    // two names (either order) is rejected and nothing is cached; a cached row filed under another date is never offered.
    for (label, decoy) in [("noscript", "<noscript><script>let clubs=[];let timetable={};</script></noscript>"),
                           ("regex literal", "<script>const re = /let clubs = []; let timetable = {};/;</script>")] {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-decoy"))
        MockHTTPBox.shared.set(39, body: decoy + timetableHTML([Fx(id: 881, slot: openSlot, title: "Decoy Guard")], emptyDays: [openSlot.date]))
        let snap = try await mockPublicClient(store: st).fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true)
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(snap.session(id: 881) != nil && st.loadSnapshot(clubId: 39)?.session(id: 881) != nil, "classes after a \(label) decoy are parsed and cached")
    }
    for names in [["Zeta", "Alpha"], ["Alpha", "Zeta"]] {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-club-conflict"))
        MockHTTPBox.shared.set(39, body: timetableHTML([Fx(id: 882, slot: openSlot, title: "Conflict")], emptyDays: [openSlot.date],
                                                       clubs: [canary] + names.map { Club(id: 250, name: $0, shortCode: "ZX") }))
        let thrown = await denialAsync { _ = try await mockPublicClient(store: st).fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true) }
        MockHTTPBox.shared.set(39, body: page39)
        try assertTrue(!thrown.isEmpty && st.loadSnapshot(clubId: 39) == nil, "club 250 named \(names.joined(separator: " then ")) is rejected and not cached (\(thrown))")
    }
    do {
        let tomorrow = LondonCalendar.addDays(to: todayIso, days: 1)!, misfiled = snapshot([todayIso: [row(883, tomorrow, "10:00")]])
        try assertTrue(misfiled.classes(for: todayIso).isEmpty && misfiled.classes(for: tomorrow).isEmpty && misfiled.session(id: 883) == nil,
                       "a cached row whose date differs from its day key is excluded from classes(for:) and session(id:)")
    }

    // curl: a child that never reads its stdin (a config larger than the pipe stalls the write) and floods stdout while
    // ignoring SIGTERM fails with the size error in under 1.5 s and is reaped.
    do {
        let pidFile = ctx.scratch("l8-curl-stall"), began = Date()
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; head -c 300000 /dev/zero; exec /bin/sleep 10"
        let big = MobileRequest(method: "POST", url: "http://127.0.0.1:9/", headers: [HTTPHeader(name: "Content-Type", value: "application/json")],
                                body: "{\"pad\":\"" + String(repeating: "x", count: 200_000) + "\"}")
        let thrown = denial { _ = try MobileBookingClient.runCurlSync(big, hooks: .init(executablePath: "/bin/sh", arguments: ["-c", script], timeoutSeconds: 8, maxOutputBytes: 100_000)) }
        let elapsed = Date().timeIntervalSince(began), pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        try assertTrue(thrown.contains("exceeded maximum size (100000 bytes)") && elapsed < 1.5 && pid.map { kill($0, 0) != 0 } == true,
                       "a stalled config write plus a flooding SIGTERM-ignoring child fails in \(String(format: "%.2f", elapsed))s and is reaped (\(thrown))")
    }

    // Store locks and counters: a contended in-process lock that frees after the injected monotonic deadline still times
    // out; a sequence at UInt64.max throws sequenceExhausted and leaves the file unchanged.
    do {
        let clock = Locked(0.0), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l8-lock"), lockTimeout: 0.5, uptime: { clock.value },
                                  betweenWidgetReads: { entered.signal(); _ = release.wait(timeout: .now() + 3) })
        DispatchQueue.global().async { _ = st.readConsistentWidgetState(); finished.signal() }
        try assertTrue(await waitFor(entered), "the widget read holds the store lock")
        // The waiter below takes its deadline at clock 0; the clock then passes it, and only after that does the lock free.
        DispatchQueue.global().async { Thread.sleep(forTimeInterval: 0.05); clock.value = 10; Thread.sleep(forTimeInterval: 0.05); release.signal() }
        let thrown = Result { try st.readPreferences() }.error
        _ = await waitFor(finished)
        guard case StoreError.lockTimedOut? = thrown as? StoreError else { throw AssertionFailure(description: "FAIL: a lock freed after the deadline must time out (\(String(describing: thrown)))") }
        let dir = ctx.scratch("l8-sequence"), file = dir.appendingPathComponent("sequence.json")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("18446744073709551615".utf8).write(to: file)
        let exhausted = Result { try SharedStateStore(primaryDirectory: dir).reserveSnapshotSequence() }.error as? StoreError
        try assertTrue(exhausted == .sequenceExhausted && (try? String(contentsOf: file, encoding: .utf8)) == "18446744073709551615",
                       "a sequence at UInt64.max throws sequenceExhausted and leaves sequence.json unchanged")
    }

    // Scripts. run-watched stops a group worker that outlives a leader exiting 0 or 7.
    for code in [0, 7] {
        let pidFile = ctx.scratch("l8-run-watched-\(code)")
        let res = try runSubprocess("/usr/bin/python3", args: ["-I", publish, "run-watched", "--timeout", "20", "--", "/bin/bash", "-c",
                                                              "/bin/sleep 30 >/dev/null 2>&1 & echo $! > '\(pidFile.path)'; exit \(code)"], timeoutSeconds: 10)
        let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for _ in 0..<100 where pid.map({ kill($0, 0) == 0 }) == true { try await Task.sleep(nanoseconds: 10_000_000) }
        try assertTrue(res.status == Int32(code) && pid.map { kill($0, 0) != 0 } == true, "run-watched returns \(code) and stops the surviving group worker")
    }

    // TERM sent to test.sh's shell alone (not its group) stops the worker while the private build folder still exists,
    // then removes the folder.
    do {
        let shRoot = ctx.scratch("l8-testsh"), probe = shRoot.appendingPathComponent("probe")
        for dir in ["Scripts", "probe"] { try fm.createDirectory(at: shRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Scripts/test.sh", "Scripts/publish.py"] { try fm.copyItem(at: root.appendingPathComponent(path), to: shRoot.appendingPathComponent(path)) }
        let tool = shRoot.appendingPathComponent("Scripts/package_app.sh")
        try """
        #!/bin/bash
        trap 'if [ -d "$TERTIA_BUILD_DIR" ]; then echo present > "$PROBE/dir-at-term"; fi; exit 0' TERM
        echo "$TERTIA_BUILD_DIR" > "$PROBE/build-dir"
        /bin/sleep 30 &
        echo $! > "$PROBE/bg.pid"; echo $$ > "$PROBE/tool.pid"
        wait

        """.write(to: tool, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let proc = Process(), exited = DispatchSemaphore(value: 0)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        proc.arguments = ["-e", "setpgrp(0, 0); exec @ARGV", "/bin/bash", shRoot.appendingPathComponent("Scripts/test.sh").path]
        proc.environment = ProcessInfo.processInfo.environment.merging(["PROBE": probe.path]) { $1 }
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { _ in exited.signal() }
        try proc.run()
        let shell = proc.processIdentifier
        defer { if proc.isRunning { kill(-shell, SIGKILL) } }
        func probed(_ name: String) -> String? { (try? String(contentsOf: probe.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for _ in 0..<1000 where probed("tool.pid") == nil || probed("bg.pid") == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        let workers = [probed("tool.pid"), probed("bg.pid")].compactMap { $0.flatMap { pid_t($0) } }, buildDir = probed("build-dir") ?? ""
        kill(shell, SIGTERM)
        let stopped = await waitFor(exited, seconds: 6)
        for _ in 0..<200 where workers.contains(where: { kill($0, 0) == 0 }) { try await Task.sleep(nanoseconds: 10_000_000) }
        try assertTrue(stopped && proc.terminationStatus != 0 && workers.count == 2 && workers.allSatisfy { kill($0, 0) != 0 } && probed("dir-at-term") == "present"
                       && !buildDir.isEmpty && !fm.fileExists(atPath: buildDir),
                       "TERM to test.sh's shell stops the worker before \(buildDir) is removed, then removes it")
    }

    // Makefile: an overlapping `make build` and `make package` with one TERTIA_BUILD_DIR keep packaging in its own
    // per-run folder; `make install` into a path with spaces succeeds.
    let rawAppBin = ProcessInfo.processInfo.environment["TERTIA_APP_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "dist/Tertia.app/Contents/MacOS/Tertia"
    let appBin = URL(fileURLWithPath: rawAppBin.hasPrefix("/") ? rawAppBin : root.appendingPathComponent(rawAppBin).path)
    let appBundle = appBin.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    do {
        let mkRoot = ctx.scratch("l8-make"), shared = mkRoot.appendingPathComponent("shared-build")
        for dir in ["Scripts", "Packaging", "bin", "fake-bin"] { try fm.createDirectory(at: mkRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Makefile", "Scripts/package_app.sh", "Scripts/publish.py", "Packaging/App-Info.plist", "Packaging/Widget-Info.plist", "LICENSE"] {
            try fm.copyItem(at: root.appendingPathComponent(path), to: mkRoot.appendingPathComponent(path))
        }
        try fm.copyItem(at: appBin, to: mkRoot.appendingPathComponent("bin/TertiaApp"))
        try fm.copyItem(at: appBundle.appendingPathComponent("Contents/PlugIns/TertiaWidget.appex/Contents/MacOS/TertiaWidget"), to: mkRoot.appendingPathComponent("bin/TertiaWidget"))
        let build = "#!/bin/sh\nset -e\nhere=\"$(cd \"$(dirname \"$0\")/..\" && pwd)\"\necho \"$TERTIA_BUILD_DIR\" >> \"$here/build-dirs\"\nmkdir -p \"$TERTIA_BUILD_DIR\"\n/bin/sleep 0.4\ncp \"$here/bin/TertiaApp\" \"$here/bin/TertiaWidget\" \"$TERTIA_BUILD_DIR/\"\n"
        for (path, text) in [("Scripts/build.sh", build), ("fake-bin/codesign", "#!/bin/sh\nexit 0\n"), ("fake-bin/iconutil", "#!/bin/sh\n: > \"$5\"\n")] {
            try text.write(to: mkRoot.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mkRoot.appendingPathComponent(path).path)
        }
        let env = ["PATH": "\(mkRoot.appendingPathComponent("fake-bin").path):/usr/bin:/bin", "TERTIA_PACKAGE_BUILD_DIR": "", "TERTIA_LOCK_TIMEOUT": "20",
                   "TERTIA_DIST_APP": mkRoot.appendingPathComponent("dist/Tertia.app").path]
        let runs = ["build", "package"].map { target in
            Task.detached { (try? runSubprocess("/usr/bin/make", args: ["-C", mkRoot.path, "--no-print-directory", target, "TERTIA_BUILD_DIR=\(shared.path)"], env: env, timeoutSeconds: 30)) }
        }
        var results: [(status: Int32, stdout: String, stderr: String, timedOut: Bool)?] = []
        for run in runs { results.append(await run.value) }
        let dirs = ((try? String(contentsOf: mkRoot.appendingPathComponent("build-dirs"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        try assertTrue(results.allSatisfy { $0?.status == 0 && $0?.timedOut == false } && dirs.count == 2 && dirs.filter({ $0 == shared.path }).count == 1 && dirs.contains { $0.contains("/.build/pkg.") }
                       && fm.fileExists(atPath: shared.appendingPathComponent("TertiaApp").path) && fm.fileExists(atPath: mkRoot.appendingPathComponent("dist/Tertia.app/Contents/MacOS/Tertia").path),
                       "overlapping make build and make package with one TERTIA_BUILD_DIR keep packaging isolated (\(dirs)) \(results.map { $0?.stderr.suffix(200) ?? "nil" })")
    }
    do {
        let target = ctx.scratch("l8-install").appendingPathComponent("Tertia Member/Example App.app")
        let res = try runSubprocess("/usr/bin/make", args: ["-C", root.path, "--no-print-directory", "-o", "package", "install", "INSTALL_APP=\(target.path)", "TERTIA_DIST_APP=\(appBundle.path)",
                                                           "LSREGISTER=/usr/bin/true", "PLUGINKIT=/usr/bin/true"], timeoutSeconds: 30)
        let verified = try runSubprocess("/usr/bin/codesign", args: ["--verify", "--deep", "--strict", target.path], timeoutSeconds: 10)
        try assertTrue(res.status == 0 && !res.timedOut && res.stdout.contains("Installed to \(target.path)") && verified.status == 0 && !verified.timedOut && fm.isExecutableFile(atPath: target.appendingPathComponent("Contents/MacOS/Tertia").path),
                       "make install into a path with spaces succeeds (\(res.stderr.suffix(300)))")
    }
}

/// Loop 9: row-bound booked state and actions across clubs, the selected-day and fallback-row checks, untrusted club
/// caches, the cross-club tear, sign-out and expiry with broken widget locks or failed Keychain deletes, timestamp and
/// metadata merges, post-deadline locks, exhausted counters, parser and transport edges, and the packaging scripts.
@MainActor func loop9(_ ctx: TestContext) async throws {
    let fm = ctx.fm, root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let publish = root.appendingPathComponent("Scripts/publish.py").path
    let stale = ScheduleViewModel.staleIntentMessage, accepted = Data("{\"statusCode\":\"accepted\"}".utf8)
    let restoreWarning = KeychainError.interactionRestoreFailed(-25308).localizedDescription, deleteError = KeychainError.osStatus(-50).localizedDescription
    func booking(_ id: Int, _ start: String, title: String? = nil) -> MemberBooking {
        MemberBooking(id: id, title: title ?? "Class \(id)", startDate: start, clubName: "Canary Wharf", trainerName: "", eventAction: "cancel")
    }
    /// A menu over `store` viewing `club` on `day` (a fresh model, as when the menu reopens).
    func menu(_ f: (vm: ScheduleViewModel, store: SharedStateStore, kc: KeychainStore, mock: MobileMock, dir: URL, mirror: URL?), _ club: Club, day: String) throws -> ScheduleViewModel {
        try f.store.seedPreferences(TertiaPreferences(clubId: club.id, clubName: club.name, clubShortCode: club.shortCode))
        let vm = ScheduleViewModel(store: f.store, keychain: f.kc, client: mockPublicClient(store: f.store), bookingClient: f.mock.client)
        vm.selectedDate = day
        return vm
    }
    /// Rewrites every listed numeric JSON field of `url` to `value` (counters at their limit).
    func setCounters(_ url: URL, _ keys: [String], to value: String) throws {
        var text = try String(contentsOf: url, encoding: .utf8)
        for key in keys { text = text.replacingOccurrences(of: "\"\(key)\":[0-9]+", with: "\"\(key)\":\(value)", options: .regularExpression) }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    let maxU64 = String(UInt64.max)
    MockHTTPBox.shared.set(39, body: page39)

    // Clubs 39 and 200 share class 901 with different titles and the member booked Canary Wharf's: Wood Wharf's card has
    // no BOOKED badge and no action (clicks send 0 requests), the widget shows no badge for 901 in every size, and Canary
    // Wharf's dated booking still cancels, naming the booked title.
    do {
        let cw = row(901, openSlot.date, openSlot.time, "Canary Ride")
        let ww = ClassSession(id: 901, date: openSlot.date, startTime: openSlot.time, endTime: "23:59", durationMinutes: 45, title: "Wood Pilates", trainer: "", clubName: "Wood Wharf")
        let f = try ctx.freshVM("l9-collide", mirror: true, seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [booking(901, isoUTC(openSlot.start), title: "Canary Ride")])
            try st.seedSnapshot(clubSnapshot([openSlot.date: [cw]]))
            try st.seedSnapshot(clubSnapshot([openSlot.date: [ww]], clubId: 200))
        })
        let wood = try menu(f, woodWharf, day: openSlot.date), before = f.mock.count
        let woodBadge = wood.badge(for: ww), woodAction = wood.classAction(for: ww)
        await wood.handleClassAction(classId: 901, expectedCancel: false, expectedToken: "tok_A", expectedClubId: 200, title: ww.title, startTime: ww.startTime, expectedDate: ww.date)
        let widget = loadWidgetState(store: SharedStateStore(primaryDirectory: f.mirror!))
        let views = (TertiaSmallWidgetView(snapshot: widget.snapshot, preferences: widget.preferences, bookedIds: widget.bookedIds).bookedIds,
                     TertiaMediumWidgetView(snapshot: widget.snapshot, preferences: widget.preferences, bookedIds: widget.bookedIds).bookedIds,
                     TertiaLargeWidgetView(snapshot: widget.snapshot, preferences: widget.preferences, bookedIds: widget.bookedIds).bookedIds)
        try assertTrue(woodBadge == .status(LondonCalendar.bookingWindowStatus(for: ww)) && woodAction == nil && f.mock.count == before
                       && widget.preferences.clubId == 200 && widget.bookedIds.isEmpty && views.0.isEmpty && views.1.isEmpty && views.2.isEmpty,
                       "Wood Wharf's same-ID card: no BOOKED badge, no action, 0 requests; the widget shows no badge in any size (\(woodBadge.label), widget \(widget.bookedIds))")
        let canaryMenu = try menu(f, canary, day: openSlot.date)
        guard canaryMenu.badge(for: cw) == .bookedCancel, let cancel = canaryMenu.classAction(for: cw) else { throw AssertionFailure(description: "FAIL: Canary Wharf's booked card offers no Cancel") }
        await cancel()
        try assertTrue(f.mock.actions(after: before).map(\.body) == ["{\"classId\":901,\"lateBooking\":false}"] && canaryMenu.bannerMessage == "Cancelled Canary Ride",
                       "Canary Wharf's dated booking cancels cleanly (\(canaryMenu.bannerMessage ?? "nil"))")
    }

    // Widget views filter on their own: an ID ambiguous inside the shown club's snapshot is never badged, a unique one is.
    do {
        let dup = clubSnapshot([todayIso: [row(905, todayIso, "23:58", "One"), row(905, todayIso, "23:59", "Two"), row(906, todayIso, "23:59")]])
        let prefs = TertiaPreferences(), ids: Set<Int> = [905, 906]
        let sizes = [TertiaSmallWidgetView(snapshot: dup, preferences: prefs, bookedIds: ids).bookedIds, TertiaMediumWidgetView(snapshot: dup, preferences: prefs, bookedIds: ids).bookedIds,
                     TertiaLargeWidgetView(snapshot: dup, preferences: prefs, bookedIds: ids).bookedIds]
        try assertTrue(sizes.allSatisfy { $0 == [906] }, "every widget size drops the ambiguous booked ID and keeps the unique one (\(sizes))")
    }

    // An unbooked ID and an undated booked ID, each in both clubs: no BOOK and no CANCEL button before any click.
    do {
        let twin = row(911, openSlot.date, openSlot.time, "Twin"), undated = row(912, openSlot.date, openSlot.time, "Undated Twin")
        let f = try ctx.freshVM("l9-ambiguous", seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [booking(912, "")])
            for club in [39, 200] { try st.seedSnapshot(clubSnapshot([openSlot.date: [twin, undated]], clubId: club)) }
        })
        f.vm.selectedDate = openSlot.date
        let badges = [f.vm.badge(for: twin), f.vm.badge(for: undated)]
        try assertTrue(f.vm.classAction(for: twin) == nil && f.vm.classAction(for: undated) == nil && badges.allSatisfy { !$0.isAction } && badges[1] == .booked,
                       "ambiguous rows offer no BOOK or CANCEL button (\(badges.map(\.label)))")
    }

    // An undated booking cancelled by its public row: once that row is retitled, rescheduled, or moved to club 200, the
    // old Cancel callback sends 0 private requests.
    let later = slot(7 * 3600), fallback = row(921, openSlot.date, openSlot.time, "Fallback Flow")
    for (label, club39, club200) in [("retitled", [row(921, openSlot.date, openSlot.time, "Fallback Flow II")], [ClassSession]()),
                                     ("rescheduled", [row(921, later.date, later.time, "Fallback Flow")], []), ("moved to club 200", [], [fallback])] {
        let f = try ctx.freshVM("l9-fallback", seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, [booking(921, "")]); try st.seedSnapshot(clubSnapshot([openSlot.date: [fallback]])) })
        f.vm.selectedDate = openSlot.date
        guard let cancel = f.vm.classAction(for: fallback) else { throw AssertionFailure(description: "FAIL: \(label): the undated booking has no Cancel action") }
        try f.store.seedSnapshot(clubSnapshot(club39.isEmpty ? [openSlot.date: []] : Dictionary(grouping: club39, by: \.date)))
        if !club200.isEmpty { try f.store.seedSnapshot(clubSnapshot([openSlot.date: club200], clubId: 200)) }
        let before = f.mock.count
        await cancel()
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale, "\(label) fallback row: the old Cancel callback sends 0 private requests (\(f.vm.bannerMessage ?? "nil"))")
    }

    // A BOOK button drawn on one day, then another day selected: the old callback sends 0 private requests.
    do {
        let bookable = row(931, openSlot.date, openSlot.time, "Day Lock"), other = LondonCalendar.addDays(to: openSlot.date, days: 1)!
        let f = try ctx.freshVM("l9-day", seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, []); try st.seedSnapshot(clubSnapshot([openSlot.date: [bookable], other: []])) })
        f.vm.selectedDate = openSlot.date
        guard let book = f.vm.classAction(for: bookable) else { throw AssertionFailure(description: "FAIL: the bookable row has no Book action") }
        f.vm.selectDate(other)
        let before = f.mock.count
        await book()
        try assertTrue(f.mock.count == before && f.vm.bannerMessage == stale, "a Book callback drawn on another day sends 0 private requests (\(f.vm.bannerMessage ?? "nil"))")
    }

    // A valid class in club 39 next to an unreadable or wrong-club snapshot-200.json: menu, CLI, and MCP refuse with 0
    // private requests and name the file to delete.
    for label in ["corrupt JSON", "wrong clubId"] {
        let valid = row(941, openSlot.date, openSlot.time, "Valid")
        let f = try ctx.freshVM("l9-untrusted", seed: { st, kc, dir, _ in
            try loginSeed(st, memberA, kc, [])
            try st.seedSnapshot(clubSnapshot([openSlot.date: [valid]]))
            let target = dir.appendingPathComponent("snapshot-200.json")
            if label == "corrupt JSON" { try Data("{".utf8).write(to: target) } else { try fm.copyItem(at: dir.appendingPathComponent("snapshot-39.json"), to: target) }
        })
        f.vm.selectedDate = openSlot.date
        let drawn = f.vm.classAction(for: valid), pub = mockPublicClient(store: f.store), before = f.mock.count
        try await pressDisabled(f.vm, valid)
        let cli = await denialAsync { _ = try await TertiaCLI.performMutation(classId: 941, isCancel: false, late: false, store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client) }
        let mcp = try toolResult(await MCPServer.handleLine(bookLine("941"), store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client))
        let named = "delete snapshot-200.json"
        try assertTrue(drawn == nil && f.mock.count == before && cli.contains(named) && mcp.isError && mcp.text.contains(named) && (f.vm.bannerMessage ?? "").contains(named),
                       "\(label) snapshot-200.json: menu, CLI, and MCP refuse with 0 private requests (\(cli))")
    }
    try assertTrue(denial { _ = try BookingAuthorization.publicSession(.untrusted(clubId: 0), classId: 1) } == "Another Tertia process is holding the store lock; try again in a moment.",
                   "a store lock timeout is reported as a busy lock, not a broken file")

    // Cross-club tear: another store adds class 951 to club 200 while the preflight lookup holds .timetables.lock; that
    // write waits for the lock, so the launch lookup sees the ID in two clubs and refuses (0 bookings sent). After a
    // dispatch, the lock is free while the reply is awaited.
    do {
        let dir = ctx.scratch("l9-tear"), kcT = ctx.keychain("l9-tear"), reads = Locked(0), blocked = Locked(false), merged = DispatchSemaphore(value: 0)
        let writer = SharedStateStore(primaryDirectory: dir, lockTimeout: 3)
        let st = SharedStateStore(primaryDirectory: dir, betweenClubSnapshotReads: { club in
            var n = 0; reads.mutate { $0 += 1; n = $0 }
            guard n == 1, club == 39 else { return }
            let done = Locked(false)
            DispatchQueue.global().async {
                _ = try? writer.mergeAndSaveSnapshot(clubId: 200, clubs: [canary, woodWharf], clubName: "Wood Wharf", clubShortCode: "WW", fetchedDays: [openSlot.date: [row(951, openSlot.date, openSlot.time)]],
                                                     fetchedRange: [openSlot.date], requestSeq: 7, syncedAt: Date())
                done.value = true; merged.signal()
            }
            Thread.sleep(forTimeInterval: 0.15)
            blocked.value = !done.value
        })
        try loginSeed(st, memberA, kcT, [])
        try st.seedSnapshot(clubSnapshot([openSlot.date: [row(951, openSlot.date, openSlot.time), row(952, openSlot.date, openSlot.time)]]))
        let sent = Locked<[String]>([]), replyMerge = Locked(false)
        let client = MobileBookingClient { req in
            if req.url.contains("/member/classes?") { return (200, Data(classesJSON([]).utf8)) }
            if req.body?.contains("951") == true { _ = blockingWait(merged, seconds: 3) } // the tear write lands between the two passes
            try MobileBookingClient.performHandoff(req) { final in sent.mutate { $0.append(final.body ?? "") } }
            if req.body?.contains("952") == true { // reply pending: a timetable write never waits for the mutation
                replyMerge.value = (try? SharedStateStore(primaryDirectory: dir, lockTimeout: 0.5).mergeAndSaveSnapshot(
                    clubId: 39, clubs: [canary, woodWharf], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [later.date: [row(953, later.date, later.time)]],
                    fetchedRange: [later.date], requestSeq: 8, syncedAt: Date())) != nil
            }
            return (200, accepted)
        }
        func authorize(_ id: Int) -> @Sendable (MemberSession, BookingsSnapshot?, SharedStateStore) throws -> Bool {
            { live, bookings, store in
                try BookingAuthorization.authorize(classId: id, isCancel: false, bookings: bookings, confirmedLate: false, now: Date()) {
                    store.lookupEntitledClass(id, clubIds: Set(live.entitledClubs(from: store.publicClubCatalog()).map(\.id)))
                }
            }
        }
        let tear = await denialAsync { _ = try await client.mutateAndSync(classId: 951, isCancel: false, session: memberA, store: st, keychain: kcT, authorize: authorize(951)) }
        let tearSent = sent.value
        _ = try await client.mutateAndSync(classId: 952, isCancel: false, session: memberA, store: st, keychain: kcT, authorize: authorize(952))
        try assertTrue(blocked.value && tear.contains("conflicting or multiple club definitions") && tearSent.isEmpty && sent.value == ["{\"classId\":952}"] && replyMerge.value,
                       "a timetable write waits for .timetables.lock during authorization (0 tear bookings sent) and proceeds while a reply is awaited (\(tear))")
    }

    // Local sign-out with an inaccessible (0o000) widget .account.lock, from the store, the menu, and CLI logout: the
    // Keychain credential is deleted, the primary state signs out (extra club 250 returns to 39), the caller hears about
    // the widget, and the mirror account files are never written unlocked.
    for caller in ["store", "menu", "cli"] {
        let f = try ctx.freshVM("l9-mirror-lock-\(caller)", mirror: true, seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, [booking(501, isoUTC(openSlot.start))]) })
        let mdir = f.mirror!, lockFile = mdir.appendingPathComponent(".account.lock"), mirrorAccount = mdir.appendingPathComponent("account.json")
        try f.store.seedPreferences(TertiaPreferences(clubId: 250, clubName: "Zeta Extra", clubShortCode: "ZX"))
        let mirrorFiles = [mirrorAccount, mdir.appendingPathComponent("bookings.json")], mirrorBefore = mirrorFiles.map { fm.contents(atPath: $0.path) }
        _ = fm.createFile(atPath: lockFile.path, contents: nil)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockFile.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockFile.path) }
        var reported = ""
        switch caller {
        case "store":
            let result = try f.store.clearSession(keychain: f.kc)
            reported = result.didClear ? result.cacheError?.localizedDescription ?? "" : ""
        case "menu":
            f.vm.signOut(); reported = f.vm.memberSession == nil && f.vm.bannerIsError ? f.vm.bannerMessage ?? "" : ""
        default:
            let res = try await captureOutput(fd: STDERR_FILENO) { await TertiaCLI.run(args: ["logout"], store: f.store, keychain: f.kc) }
            reported = res.code == 1 ? res.out : ""
        }
        try assertTrue(!reported.isEmpty && (try f.kc.readSession()) == nil && f.store.loadBookings(for: memberA) == nil && f.store.loadPreferences().clubId == 39
                       && mirrorFiles.map { fm.contents(atPath: $0.path) } == mirrorBefore && !mirrorBefore.contains(nil),
                       "\(caller) sign-out with a locked-out widget lock signs out locally and reports the widget (\(reported))")
    }

    // A manual Refresh gets HTTP 401 and the Keychain delete then fails: cached bookings are invalidated on disk, other
    // surfaces are notified, and a reopened menu, cached `tertia bookings`, and the widget show 0 actions and 0 badges.
    do {
        let statuses = Locked<[Int32]>([]), notes = Locked(0)
        let hooks = KeychainStore.Hooks(getInteractionAllowed: { var status: Int32 = 0; statuses.mutate { if !$0.isEmpty { status = $0.removeFirst() } }; return (status, true) })
        let r = row(961, openSlot.date, openSlot.time)
        let f = try ctx.freshVM("l9-401-delete", hooks: hooks, mirror: true, onChange: { notes.mutate { $0 += 1 } }, seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [booking(961, isoUTC(openSlot.start))]); try st.seedSnapshot(clubSnapshot([openSlot.date: [r]]))
        })
        f.mock.classesStatus.value["tok_A"] = 401; f.mock.classesDelay.value["tok_A"] = 0.3
        drain(f.mock.classesArrived)
        let before = notes.value
        let running = Task { await f.vm.load(forceRefresh: true) }
        _ = await waitFor(f.mock.classesArrived)
        statuses.value = [0, -50] // the token read succeeds, the Keychain delete fails
        await running.value
        let widgetStore = SharedStateStore(primaryDirectory: f.mirror!), reopened = try menu(f, canary, day: openSlot.date)
        let cached = await denialAsync { _ = try await TertiaCLI.memberBookings(refresh: false, store: f.store, keychain: f.kc, bookingClient: f.mock.client) }
        try assertTrue((try f.kc.readSession())?.token == "tok_A" && f.store.loadBookings(for: memberA) == nil && widgetStore.loadBookedIds().isEmpty
                       && notes.value - before >= 2 && reopened.bookings == nil && reopened.classAction(for: r) == nil && !reopened.badge(for: r).isAction
                       && cached.contains("No cached bookings") && loadWidgetState(store: widgetStore).bookedIds.isEmpty,
                       "a 401 refresh with a failed Keychain delete invalidates the cache and notifies (\(notes.value - before) notes); every surface shows 0 actions and badges")
    }

    // Sign-out whose Keychain read reports a UI-restore warning and whose delete fails: the menu and CLI logout report both.
    for caller in ["menu", "cli"] {
        let gets = Locked<[Int32]>([]), restores = Locked<[Int32]>([])
        let hooks = KeychainStore.Hooks(getInteractionAllowed: { var status: Int32 = 0; gets.mutate { if !$0.isEmpty { status = $0.removeFirst() } }; return (status, true) },
                                        setInteractionAllowed: { allowed in var status: Int32 = 0; if allowed { restores.mutate { if !$0.isEmpty { status = $0.removeFirst() } } }; return status })
        let f = try ctx.freshVM("l9-signout-\(caller)", hooks: hooks, seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, []) })
        gets.value = [0, -50]; restores.value = [-25308]
        var reported = ""
        if caller == "menu" { f.vm.signOut(); reported = f.vm.bannerMessage ?? "" }
        else { reported = try await captureOutput(fd: STDERR_FILENO) { await TertiaCLI.run(args: ["logout"], store: f.store, keychain: f.kc) }.out }
        try assertTrue(reported.contains(deleteError) && reported.contains(restoreWarning) && (try f.kc.readSession()) == memberA,
                       "\(caller) sign-out reports the failed delete and the Keychain warning (\(reported))")
    }

    // Snapshot merges in one persisted millisecond: a host write 0.4 ms after widget request 100 never displaces it, so the
    // late widget request 50 changes nothing; with equal-time metadata, request 50's obsolete club name never wins.
    do {
        let stamp = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 120).rounded(.down))
        func pair(_ name: String) -> (host: SharedStateStore, widget: SharedStateStore) {
            let mdir = ctx.scratch("\(name)-widget")
            return (SharedStateStore(primaryDirectory: ctx.scratch(name), mirrorDirectory: mdir), SharedStateStore(primaryDirectory: mdir))
        }
        func merge(_ st: SharedStateStore, _ id: Int, seq: UInt64, at: Date, name: String = "Canary Wharf", short: String = "CANARY") throws {
            _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: name, clubShortCode: short, fetchedDays: [todayIso: [row(id, todayIso, "10:00")]],
                                            fetchedRange: [todayIso], requestSeq: seq, syncedAt: at)
        }
        let rows = pair("l9-submilli")
        try merge(rows.widget, 1001, seq: 100, at: stamp)
        try merge(rows.host, 1002, seq: 5, at: stamp.addingTimeInterval(0.0004))
        try merge(rows.widget, 1003, seq: 50, at: stamp)
        let names = pair("l9-meta")
        try merge(names.widget, 1011, seq: 100, at: stamp)
        try merge(names.host, 1012, seq: 5, at: stamp)
        try merge(names.widget, 1013, seq: 50, at: stamp, name: "Canary Wharf Old", short: "OLD")
        let kept = rows.widget.loadSnapshot(clubId: 39), named = names.widget.loadSnapshot(clubId: 39)
        try assertTrue(kept?.classes(for: todayIso).map(\.id) == [1001] && named?.clubName == "Canary Wharf" && named?.clubShortCode == "CANARY",
                       "widget request 100 survives a sub-millisecond host write and late request 50 (\(kept?.classes(for: todayIso).map(\.id) ?? [])); its stale name never wins (\(named?.clubName ?? "nil"))")
    }

    // Locks released only after their monotonic deadline: .mutation.lock, a store file lock, and `publish.py lock` all
    // time out and do 0 protected work.
    do {
        let dir = ctx.scratch("l9-deadline"), clock = Locked(0.0), work = Locked(0)
        let st = SharedStateStore(primaryDirectory: dir, lockTimeout: 0.3, mutationLockTimeout: 0.3, uptime: { clock.value })
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func hold(_ name: String) -> Int32 { let fd = open(dir.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600); flock(fd, LOCK_EX); return fd }
        /// Passes the injected deadline, then frees `fd` (the waiter must already have timed out by then).
        func releaseLate(_ fd: Int32) { DispatchQueue.global().async { Thread.sleep(forTimeInterval: 0.05); clock.value += 10; Thread.sleep(forTimeInterval: 0.05); flock(fd, LOCK_UN); close(fd) } }
        clock.value = 0; releaseLate(hold(".mutation.lock"))
        let mutation = await denialAsync { try await st.withMutationLock(classId: 1) { @Sendable in work.mutate { $0 += 1 } } }
        clock.value = 100; releaseLate(hold(".sequence.lock"))
        let file = Result { try st.reserveSnapshotSequence() }.error as? StoreError
        let lockPath = dir.appendingPathComponent("publish.lock").path, marker = dir.appendingPathComponent("protected-work")
        // In-process holder and stubbed clock: the first wait passes the deadline and only then frees the lock.
        let stub = "import fcntl, os, runpy, sys, time\npath, lock, marker = sys.argv[1:4]\nholder = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)\n"
                 + "fcntl.flock(holder, fcntl.LOCK_EX)\nt = [0.0]\ntime.monotonic = lambda: t[0]\n"
                 + "def late(_):\n    t[0] += 10\n    fcntl.flock(holder, fcntl.LOCK_UN)\ntime.sleep = late\n"
                 + "sys.argv = [path, 'lock', '--timeout', '0.3', lock, '/usr/bin/touch', marker]\nrunpy.run_path(path, run_name='__main__')\n"
        let script = try runSubprocess("/usr/bin/python3", args: ["-I", "-c", stub, publish, lockPath, marker.path], timeoutSeconds: 5)
        try assertTrue(mutation.contains(".mutation.lock") && file == .lockTimedOut(".sequence.lock") && work.value == 0 && !fm.fileExists(atPath: dir.appendingPathComponent("sequence.json").path)
                       && script.status != 0 && script.stderr.contains("timed out") && !fm.fileExists(atPath: marker.path),
                       "locks freed after the deadline time out with 0 protected work (\(mutation) | \(String(describing: file)) | \(script.stderr))")
    }

    // Private counters at UInt64.max: a refresh and a mutation fail with revisionExhausted (0 requests, account.json
    // unchanged); sign-out still works.
    do {
        let dir = ctx.scratch("l9-revision"), kcR = ctx.keychain("l9-revision"), st = SharedStateStore(primaryDirectory: dir), mock = MobileMock()
        try loginSeed(st, memberA, kcR, [booking(502, isoUTC(lateSlot.start))])
        let marker = dir.appendingPathComponent("account.json")
        try setCounters(marker, ["revision", "minValidSyncRevision", "lastIssuedSyncSeq", "lastCommittedSyncSeq"], to: maxU64)
        let saved = fm.contents(atPath: marker.path)
        let refresh = await denialAsync { _ = try await mock.client.syncBookings(for: memberA, store: st, keychain: kcR) }
        let mutation = await denialAsync { _ = try await mock.client.mutateAndSync(classId: 502, isCancel: true, session: memberA, store: st, keychain: kcR) { _, _, _ in true } }
        let exhausted = StoreError.revisionExhausted.localizedDescription, unchanged = fm.contents(atPath: marker.path) == saved
        let signOut = try st.clearSession(keychain: kcR)
        try assertTrue(refresh.contains(exhausted) && mutation.contains(exhausted) && unchanged && mock.count == 0 && signOut.didClear && (try kcR.readSession()) == nil,
                       "exhausted private counters refuse refresh and mutation without writes (\(refresh) | \(mutation)); sign-out still clears")
    }

    // Public counters at UInt64.max (sequence.json, public-clubs.json, snapshot-39.json): a refresh fails until the files
    // named by sequenceExhausted are removed; then a refresh updates all three.
    do {
        let dir = ctx.scratch("l9-sequence"), st = SharedStateStore(primaryDirectory: dir), pub = mockPublicClient(store: st)
        _ = try await pub.fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true)
        try Data(maxU64.utf8).write(to: dir.appendingPathComponent("sequence.json"))
        try setCounters(dir.appendingPathComponent("public-clubs.json"), ["seq"], to: maxU64)
        let snapFile = dir.appendingPathComponent("snapshot-39.json")
        var snapText = try String(contentsOf: snapFile, encoding: .utf8)
        snapText = snapText.replacingOccurrences(of: "(\"20[0-9-]{8}\"):[0-9]+", with: "$1:\(maxU64)", options: .regularExpression)
        try snapText.write(to: snapFile, atomically: true, encoding: .utf8)
        try setCounters(snapFile, ["metaRevision"], to: maxU64)
        let blocked = await denialAsync { _ = try await pub.fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true) }
        let advice = StoreError.sequenceExhausted.localizedDescription
        try assertTrue(blocked.contains(advice) && ["sequence.json", "public-clubs.json", "snapshot-*.json"].allSatisfy(advice.contains), "an exhausted refresh names the files to delete (\(blocked))")
        for name in try fm.contentsOfDirectory(atPath: dir.path) where name == "sequence.json" || name == "public-clubs.json" || (name.hasPrefix("snapshot-") && name.hasSuffix(".json")) {
            try fm.removeItem(at: dir.appendingPathComponent(name))
        }
        _ = try await pub.fetchSchedule(clubId: 39, date: openSlot.date, forceRefresh: true)
        let texts = ["sequence.json", "public-clubs.json", "snapshot-39.json"].map { (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) ?? maxU64 }
        try assertTrue(texts.allSatisfy { !$0.contains(maxU64) } && st.loadSnapshot(clubId: 39)?.session(id: 501) != nil,
                       "after those removals a refresh rewrites sequence.json, public-clubs.json, and snapshot-39.json")
    }

    // A missing primary preferences.json with a stale widget copy (Wood Wharf 200): reconciling resets both to club 39.
    do {
        let dir = ctx.scratch("l9-prefs"), mdir = ctx.scratch("l9-prefs-widget"), widget = SharedStateStore(primaryDirectory: mdir)
        try widget.seedPreferences(TertiaPreferences(clubId: 200, clubName: "Wood Wharf", clubShortCode: "WW"))
        let host = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
        let mirrorError = try host.reconcileAccountMirror(for: nil, keychain: ctx.keychain("l9-prefs"))
        try assertTrue(mirrorError == nil && host.loadPreferences().clubId == 39 && widget.loadPreferences().clubId == 39 && widget.loadPreferences().clubName == "Canary Wharf",
                       "a stale widget preferences.json follows the missing primary file back to Canary Wharf (\(widget.loadPreferences().clubId))")
    }

    // filterSessions never traps on extreme grace values.
    do {
        let today = row(971, todayIso, "23:59"), now = LondonCalendar.londonWallDate(dateIso: todayIso, hhmm: "00:00")!
        let kept = [Int.min, Int.max, 0, 15].map { LondonCalendar.filterSessions([today], period: .all, search: "", selectedDate: todayIso, now: now, includePastGraceMinutes: $0).count }
        try assertTrue(kept == [0, 1, 1, 1], "filterSessions handles grace Int.min, Int.max, 0, and 15 (\(kept))")
    }

    // MCP: a class_id exponent at Int.min is -32602 and the same server answers a ping next; only RFC 8259 whitespace may
    // wrap a request (U+00A0 is a parse error).
    do {
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l9-mcp")), kcM = ctx.keychain("l9-mcp"), mock = MobileMock(), pub = mockPublicClient(store: st)
        func mcp(_ line: String) async -> String? { await MCPServer.handleLine(line, store: st, keychain: kcM, client: pub, bookingClient: mock.client) }
        let ping = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        let codes = [try errorCode(await mcp(bookLine("1e-9223372036854775808"))), try errorCode(await mcp(bookLine("1.5e-9223372036854775808")))]
        let next = try decodeJSON(await mcp(ping))["result"] != nil
        let nbsp = try errorCode(await mcp("\u{00A0}" + ping + "\u{00A0}")), ascii = try decodeJSON(await mcp(" \t" + ping + "\t "))["result"] != nil
        try assertTrue(codes == [-32602, -32602] && next && nbsp == -32700 && ascii && mock.count == 0,
                       "MCP rejects Int.min exponents (\(codes)), then answers ping; U+00A0 is -32700, space and tab are accepted")
    }

    // Parser: a regex literal after an `if (...)` condition and a division after `count++` never hide the real declarations.
    for (label, decoy) in [("regex after if", "if (ready) /let clubs = []; let timetable = {};/.test(x);"), ("postfix division", "var count = 0; count++ / 2;")] {
        let page = timetableHTML([Fx(id: 981, slot: openSlot, title: "Real Class")], emptyDays: [openSlot.date]).replacingOccurrences(of: "<script>\n", with: "<script>\n\(decoy) ")
        let parsed = try HTMLTimetableParser.parse(html: page, clubId: 39)
        try assertTrue(page.contains(decoy) && parsed.days[openSlot.date]?.contains { $0.id == 981 } == true && parsed.clubs.count == 3, "\(label): the real timetable is selected")
    }

    // curl: a child that exits 0 at once while its background subshell floods stdout and holds stderr fails with the size
    // error in under 1.5 s.
    do {
        let pidFile = ctx.scratch("l9-curl-bg"), began = Date()
        let script = "(head -c 300000 /dev/zero; exec /bin/sleep 10) & echo $! > '\(pidFile.path)'; exit 0"
        let thrown = denial { _ = try MobileBookingClient.runCurlSync(MobileRequest(method: "GET", url: "http://127.0.0.1:9/", headers: []),
                                                                      hooks: .init(executablePath: "/bin/sh", arguments: ["-c", script], timeoutSeconds: 8, maxOutputBytes: 100_000)) }
        let elapsed = Date().timeIntervalSince(began)
        if let pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { kill(pid, SIGKILL) }
        try assertTrue(thrown.contains("exceeded maximum size (100000 bytes)") && elapsed < 1.5,
                       "a background flood after the child exited fails in \(String(format: "%.2f", elapsed))s (\(thrown))")
    }

    // A transport that records a send and throws without its launch gate invalidates the cached bookings; a launch-gate
    // refusal keeps them.
    for skipGate in [true, false] {
        let dir = ctx.scratch("l9-ungated"), kcU = ctx.keychain("l9-ungated"), st = SharedStateStore(primaryDirectory: dir), passes = Locked(0), sends = Locked(0)
        try loginSeed(st, memberA, kcU, [booking(502, isoUTC(lateSlot.start))])
        let client = MobileBookingClient { req in
            if skipGate { sends.mutate { $0 += 1 }; throw BookingClientError.transportError("simulated send without the gate") }
            try MobileBookingClient.performHandoff(req) { _ in sends.mutate { $0 += 1 } }
            return (200, accepted)
        }
        let thrown = await denialAsync {
            _ = try await client.mutateAndSync(classId: 501, isCancel: false, session: memberA, store: st, keychain: kcU) { _, _, _ in
                var n = 0; passes.mutate { $0 += 1; n = $0 }
                if n == 2 { throw BookingDenied("refused at launch") }
                return false
            }
        }
        let valid = st.loadBookings(for: memberA) != nil
        try assertTrue(!thrown.isEmpty && sends.value == (skipGate ? 1 : 0) && valid == !skipGate,
                       skipGate ? "an ungated transport failure invalidates the cache (\(thrown))" : "a launch-gate refusal keeps the cache valid (\(thrown))")
    }

    // Scripts. run-watched exits 125 with an error when its process group survives SIGKILL (stubbed).
    do {
        let stub = "import os, runpy, sys, time\nt = [0.0]\ntime.monotonic = lambda: t.__setitem__(0, t[0] + 0.5) or t[0]\nos.killpg = lambda pgid, sig: None\n"
                 + "path = sys.argv[1]\nsys.argv = [path, 'run-watched', '--timeout', '30', '--', '/usr/bin/true']\nrunpy.run_path(path, run_name='__main__')\n"
        let res = try runSubprocess("/usr/bin/python3", args: ["-I", "-c", stub, publish], timeoutSeconds: 10)
        try assertTrue(res.status == 125 && res.stderr.contains("survived SIGKILL"), "run-watched exits 125 when the group survives SIGKILL (\(res.status): \(res.stderr))")
    }

    // `make clean` waits for the build and package locks: while either is held it fails and changes nothing; once free it
    // empties .build and dist except lock files and live runs' folders, and removes an overridden TERTIA_DIST_APP.
    do {
        let mkRoot = ctx.scratch("l9-clean"), custom = mkRoot.appendingPathComponent("custom dist/Custom App.app")
        try fm.createDirectory(at: mkRoot.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        for path in ["Makefile", "Scripts/publish.py"] { try fm.copyItem(at: root.appendingPathComponent(path), to: mkRoot.appendingPathComponent(path)) }
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try probe.run(); probe.waitUntilExit()
        let live = getpid(), dead = probe.processIdentifier
        let kept = [".build/.build.lock", ".build/pkg.\(live)", "dist/.Tertia.app.lock", "dist/.Tertia.app.stage.\(live)"]
        let removed = [".build/direct/TertiaApp", ".build/pkg.\(dead)", ".build/CACHEDIR.TAG", "dist/Tertia.app/Contents/Info.plist", "dist/.Tertia.app.stage.\(dead)", "dist/previews/a.png"]
        let customStage = mkRoot.appendingPathComponent("custom dist/.Custom App.app.stage.\(dead)")
        try fm.createDirectory(at: customStage, withIntermediateDirectories: true)
        for path in kept + removed + ["custom dist/Custom App.app/Contents/Info.plist"] {
            let url = mkRoot.appendingPathComponent(path), isLock = path.hasSuffix(".lock"), isDir = !isLock && !path.contains(".plist") && !path.contains(".png") && !path.hasSuffix("TertiaApp") && !path.hasSuffix("TAG")
            try fm.createDirectory(at: isDir ? url : url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !isDir { _ = fm.createFile(atPath: url.path, contents: Data()) }
        }
        try markTertiaBundle(custom) // `make clean` removes an overridden TERTIA_DIST_APP only when it is a Tertia bundle
        func clean() throws -> Int32 {
            try runSubprocess("/usr/bin/make", args: ["-C", mkRoot.path, "--no-print-directory", "clean", "TERTIA_DIST_APP=\(custom.path)"], env: ["PATH": "/usr/bin:/bin", "TERTIA_LOCK_TIMEOUT": "0.3"], timeoutSeconds: 10).status
        }
        var blockedIntact = true
        for lock in [".build/.build.lock", "dist/.Tertia.app.lock"] {
            let fd = open(mkRoot.appendingPathComponent(lock).path, O_RDWR); flock(fd, LOCK_EX)
            let status = try clean()
            flock(fd, LOCK_UN); close(fd)
            blockedIntact = blockedIntact && status != 0 && (kept + removed).allSatisfy { fm.fileExists(atPath: mkRoot.appendingPathComponent($0).path) }
        }
        let status = try clean()
        let survivors = kept.filter { fm.fileExists(atPath: mkRoot.appendingPathComponent($0).path) }, leftovers = removed.filter { fm.fileExists(atPath: mkRoot.appendingPathComponent($0).path) }
        try assertTrue(blockedIntact && status == 0 && survivors == kept && leftovers.isEmpty && !fm.fileExists(atPath: custom.path) && !fm.fileExists(atPath: customStage.path),
                       "make clean is blocked by either held lock, then keeps only locks and live runs (left over: \(leftovers), kept: \(survivors))")
    }

    // `make register` failing for an INSTALL_APP with spaces and a quote prints a retry command that, run as printed,
    // registers exactly that bundle with lsregister and pluginkit.
    do {
        let scratch = ctx.scratch("l9-register"), target = scratch.appendingPathComponent("Member's Apps/Tertia Club.app").path, log = scratch.appendingPathComponent("calls.log").path
        let recorder = scratch.appendingPathComponent("record")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s|' \"$(basename \"$0\")\" \"$@\" >> '\(log)'; echo >> '\(log)'\n".write(to: recorder, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
        let failed = try runSubprocess("/usr/bin/make", args: ["-C", root.path, "--no-print-directory", "register", "INSTALL_APP=\(target)", "LSREGISTER=/usr/bin/false"], timeoutSeconds: 10)
        let retry = failed.stderr.components(separatedBy: "to retry, run: ").last?.split(separator: "\n").first.map(String.init) ?? ""
        let rerun = try runSubprocess("/bin/sh", args: ["-c", "cd '\(root.path)' && \(retry) LSREGISTER='\(recorder.path)' PLUGINKIT='\(recorder.path)'"], timeoutSeconds: 10)
        let calls = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        try assertTrue(failed.status != 0 && retry.hasPrefix("make register INSTALL_APP=") && rerun.status == 0 && !rerun.timedOut
                       && calls == ["record|-f|\(target)|", "record|-a|\(target)/Contents/PlugIns/TertiaWidget.appex|"],
                       "the printed retry command registers exactly \(target) (\(retry) -> \(calls))")
    }

    // `make install` copying dist/Tertia.app (paused) while package_app.sh publishes a new one: the package waits for the
    // copy under dist/.Tertia.app.lock, the installed bundle verifies, and a stage left by a dead install is removed.
    do {
        let mkRoot = ctx.scratch("l9-install-race"), installDir = mkRoot.appendingPathComponent("Install Dir"), target = installDir.appendingPathComponent("Tertia.app")
        let rawAppBin = ProcessInfo.processInfo.environment["TERTIA_APP_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "dist/Tertia.app/Contents/MacOS/Tertia"
        let appBundle = URL(fileURLWithPath: rawAppBin.hasPrefix("/") ? rawAppBin : root.appendingPathComponent(rawAppBin).path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for dir in ["Scripts", "Packaging", "bin", "fake-bin", "dist"] { try fm.createDirectory(at: mkRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Makefile", "Scripts/package_app.sh", "Scripts/publish.py", "Packaging/App-Info.plist", "Packaging/Widget-Info.plist", "LICENSE"] {
            try fm.copyItem(at: root.appendingPathComponent(path), to: mkRoot.appendingPathComponent(path))
        }
        try fm.copyItem(at: appBundle, to: mkRoot.appendingPathComponent("dist/Tertia.app"))
        try fm.copyItem(at: appBundle.appendingPathComponent("Contents/MacOS/Tertia"), to: mkRoot.appendingPathComponent("bin/TertiaApp"))
        try fm.copyItem(at: appBundle.appendingPathComponent("Contents/PlugIns/TertiaWidget.appex/Contents/MacOS/TertiaWidget"), to: mkRoot.appendingPathComponent("bin/TertiaWidget"))
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try probe.run(); probe.waitUntilExit()
        let deadStage = installDir.appendingPathComponent(".Tertia.app.stage.\(probe.processIdentifier)")
        try fm.createDirectory(at: deadStage, withIntermediateDirectories: true)
        let here = mkRoot.path
        let scripts = [
            ("Scripts/build.sh", "#!/bin/sh\nset -e\n[ -e '\(here)/copy-done' ] || : > '\(here)/overlap'\nmkdir -p \"$TERTIA_BUILD_DIR\"\ncp '\(here)/bin/TertiaApp' '\(here)/bin/TertiaWidget' \"$TERTIA_BUILD_DIR/\"\n"),
            ("fake-bin/cp", "#!/bin/sh\ncase \"$2\" in */dist/Tertia.app) : > '\(here)/copy-start'; /bin/sleep 0.8; /bin/cp \"$@\"; s=$?; : > '\(here)/copy-done'; exit $s;; esac\nexec /bin/cp \"$@\"\n"),
            ("fake-bin/iconutil", "#!/bin/sh\n: > \"$5\"\n"),
        ]
        for (path, text) in scripts {
            try text.write(to: mkRoot.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mkRoot.appendingPathComponent(path).path)
        }
        let env = ["PATH": "\(mkRoot.appendingPathComponent("fake-bin").path):/usr/bin:/bin", "TERTIA_PACKAGE_BUILD_DIR": "", "TERTIA_LOCK_TIMEOUT": "20",
                   "TERTIA_DIST_APP": mkRoot.appendingPathComponent("dist/Tertia.app").path]
        let install = Task.detached {
            try? runSubprocess("/usr/bin/make", args: ["-C", here, "--no-print-directory", "-o", "package", "install", "INSTALL_APP=\(target.path)", "LSREGISTER=/usr/bin/true", "PLUGINKIT=/usr/bin/true"],
                               env: env, timeoutSeconds: 30)
        }
        for _ in 0..<500 where !fm.fileExists(atPath: mkRoot.appendingPathComponent("copy-start").path) { try await Task.sleep(nanoseconds: 10_000_000) }
        let package = try runSubprocess("/bin/bash", args: [mkRoot.appendingPathComponent("Scripts/package_app.sh").path], env: env, timeoutSeconds: 30)
        let installed = await install.value
        let verified = try runSubprocess("/usr/bin/codesign", args: ["--verify", "--deep", "--strict", target.path], timeoutSeconds: 10)
        try assertTrue(installed?.status == 0 && installed?.timedOut == false && package.status == 0 && !package.timedOut && verified.status == 0 && !verified.timedOut && !fm.fileExists(atPath: mkRoot.appendingPathComponent("overlap").path)
                       && fm.fileExists(atPath: mkRoot.appendingPathComponent("copy-done").path) && !fm.fileExists(atPath: deadStage.path),
                       "a package run waits for the paused install copy; the installed bundle verifies and the dead stage is gone (\(installed?.stderr.suffix(300) ?? "nil") | \(package.stderr.suffix(300)))")
    }
}

/// Loop 10 regressions: late confirmations bound to the booking entries, public fallbacks bound to the booked club, owner
/// identity beyond the token, sign-out and expiry cleanup, sync counters, row-matched starts, widget row tokens, day
/// switches and stored-row checks under the mutation lock, the widget's midnight fetch, snapshot clocks, the parser,
/// bundle-guarded publishing, password input, login counts, self-test isolation, and the test harness cleanup.
@MainActor func loop10(_ ctx: TestContext) async throws {
    let fm = ctx.fm, root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let publish = root.appendingPathComponent("Scripts/publish.py").path, stale = ScheduleViewModel.staleIntentMessage
    let tomorrowIso = LondonCalendar.addDays(to: todayIso, days: 1)!
    func clock(_ day: String, _ hhmm: String) -> Date { LondonCalendar.londonWallDate(dateIso: day, hhmm: hhmm)! }
    func booked(_ id: Int, _ start: String, club: String = "Canary Wharf", title: String = "Row") -> MemberBooking {
        MemberBooking(id: id, title: title, startDate: start, clubName: club, trainerName: "", eventAction: "cancel")
    }
    func wood(_ id: Int, _ day: String, _ hhmm: String) -> ClassSession {
        ClassSession(id: id, date: day, startTime: hhmm, endTime: "23:59", durationMinutes: 45, title: "Row", trainer: "", clubName: "Wood Wharf")
    }
    /// Another store holds `.mutation.lock` of `dir` until `release` is signalled (returns once it is held).
    func holdMutationLock(_ dir: URL) async throws -> (release: DispatchSemaphore, task: Task<Void, Error>) {
        let holder = SharedStateStore(primaryDirectory: dir), held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let task = Task.detached { try await holder.withMutationLock(classId: 999) { held.signal(); _ = await waitFor(release, seconds: 4) } }
        try assertTrue(await waitFor(held), "another process holds .mutation.lock")
        return (release, task)
    }
    func cancelLine(_ id: Int, late: Bool) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"cancel_booking\",\"arguments\":{\"class_id\":\(id),\"late_booking\":\(late)}}}"
    }
    MockHTTPBox.shared.set(39, body: page39)

    // BUG 1: a late confirmation armed on 11:00 Yoga never carries over to 12:00 Ride under the same ID, owner, club, and
    // date: the old Confirm callback sends 0 requests and Ride needs its own first tap.
    do {
        let nine = clock(todayIso, "09:00"), yoga = row(701, todayIso, "11:00", "Yoga"), ride = row(701, todayIso, "12:00", "Ride")
        let f = try ctx.freshVM("l10-confirm", seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [booked(701, isoUTC(clock(todayIso, "11:00")), title: "Yoga")])
            try st.seedSnapshot(clubSnapshot([todayIso: [yoga]]))
        })
        f.vm.nowOverride = nine
        try await click(f.vm, yoga)
        guard f.vm.isConfirmingLateCancel(701), let oldConfirm = f.vm.classAction(for: yoga, now: nine) else { throw AssertionFailure(description: "FAIL: Yoga's late confirmation is armed") }
        try syncSeed(f.store, memberA, f.kc, [booked(701, isoUTC(clock(todayIso, "12:00")), title: "Ride")])
        try f.store.seedSnapshot(clubSnapshot([todayIso: [ride]]))
        f.vm.syncFromDisk()
        let before = f.mock.count, rearmed = f.vm.isConfirmingLateCancel(701)
        await oldConfirm()
        let afterOld = f.mock.count
        try await click(f.vm, ride)
        try assertTrue(!rearmed && afterOld == before && f.mock.count == before && f.vm.isConfirmingLateCancel(701) && f.vm.bannerMessage == ScheduleViewModel.lateConfirmMessage,
                       "BUG 1: the Yoga confirmation is dropped for Ride; the old Confirm sends 0 requests and Ride's first tap only arms its own confirmation")
    }

    // BUG 2: an undated Canary Wharf booking is never judged by a Wood Wharf row with its ID (CLI and MCP refuse, 0
    // requests); a Canary Wharf row more than 3h away cancels with lateBooking false, one 3h or less away needs --late.
    do {
        let f = try ctx.freshVM("l10-undated", seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, [booked(702, "")]) })
        f.mock.bookings.value["tok_A"] = classesJSON([(702, "")])
        let pub = mockPublicClient(store: f.store)
        func cli(late: Bool) async -> String {
            await denialAsync { _ = try await TertiaCLI.performMutation(classId: 702, isCancel: true, late: late, store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client) }
        }
        let six = slot(6 * 3600), five = slot(5 * 3600), two = slot(2 * 3600)
        try f.store.seedSnapshot(clubSnapshot([six.date: [wood(702, six.date, six.time)]], clubId: 200))
        var before = f.mock.count
        let cliWood = await cli(late: false)
        let mcpWood = try toolResult(await MCPServer.handleLine(cancelLine(702, late: true), store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client))
        try assertTrue(!cliWood.isEmpty && mcpWood.isError && f.mock.count == before, "BUG 2: a Wood Wharf row never dates a Canary Wharf booking (CLI: \(cliWood); MCP: \(mcpWood.text))")
        try f.store.seedSnapshot(clubSnapshot([six.date: []], clubId: 200))
        try f.store.seedSnapshot(clubSnapshot([five.date: [row(702, five.date, five.time)]]))
        before = f.mock.count
        let farCancel = await cli(late: false)
        let farSent = f.mock.actions(after: before).map(\.body)
        try f.store.seedSnapshot(clubSnapshot([two.date: [row(702, two.date, two.time)]]))
        before = f.mock.count
        let unconfirmed = await cli(late: false)
        let refused = f.mock.count == before
        let mcpLate = try toolResult(await MCPServer.handleLine(cancelLine(702, late: true), store: f.store, keychain: f.kc, client: pub, bookingClient: f.mock.client))
        try assertTrue(farCancel.isEmpty && farSent == ["{\"classId\":702,\"lateBooking\":false}"] && unconfirmed.contains("3 hours or less") && refused && !mcpLate.isError
                       && f.mock.actions(after: before).map(\.body) == ["{\"classId\":702,\"lateBooking\":true}"],
                       "BUG 2: a Canary Wharf row dates the undated booking: >3h sends lateBooking false; <=3h needs the late flag, then sends true (\(unconfirmed))")
    }

    // BUG 3: owner B signs in with the same token string while owner A's Book waits on .mutation.lock: A sends 0 mutations,
    // and A's late expiry leaves B's credential and bookings alone.
    do {
        let ownerA = MemberSession(token: "tok_S", id: 1, name: "A", email: "a@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
        let ownerB = MemberSession(token: "tok_S", id: 2, name: "B", email: "b@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "", clubs: [canary, woodWharf])
        let r = row(703, openSlot.date, openSlot.time)
        let f = try ctx.freshVM("l10-owner", seed: { st, kc, _, _ in try loginSeed(st, ownerA, kc, []); try st.seedSnapshot(clubSnapshot([openSlot.date: [r]])) })
        let lock = try await holdMutationLock(f.dir), before = f.mock.count
        let queued = Task { try await click(f.vm, r) }
        for _ in 0..<1000 where f.vm.busyClassId != 703 { await Task.yield() }
        let locked = f.vm.isDaySwitchLocked
        _ = try SharedStateStore(primaryDirectory: f.dir).commitLogin(ownerB, keychain: f.kc)
        lock.release.signal()
        try await queued.value
        _ = try? await lock.task.value
        try syncSeed(f.store, ownerB, f.kc, [booked(704, isoUTC(farSlot.start))])
        let expiry = f.store.expireSession(for: ownerA, keychain: f.kc)
        try assertTrue(locked && f.mock.actions(after: before).isEmpty && expiryKind(expiry) == "superseded" && (try f.kc.readSession()) == ownerB
                       && f.store.loadBookings(for: ownerB)?.bookedIds == [704],
                       "BUG 3: owner A's queued Book sends 0 mutations after owner B reuses its token; A's expiry keeps B's credential and bookings")
    }

    // BUG 4 and BUG 5: the Keychain read succeeds and the delete fails (-50).
    do {
        let statuses = Locked<[Int32]>([]), notes = Locked(0)
        let hooks = KeychainStore.Hooks(getInteractionAllowed: { var status: Int32 = 0; statuses.mutate { if !$0.isEmpty { status = $0.removeFirst() } }; return (status, true) })
        let r = row(705, farSlot.date, farSlot.time)
        let f = try ctx.freshVM("l10-signout", hooks: hooks, mirror: true, onChange: { notes.mutate { $0 += 1 } }, seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [booked(705, isoUTC(farSlot.start))]); try st.seedSnapshot(clubSnapshot([farSlot.date: [r]]))
        })
        let widget = SharedStateStore(primaryDirectory: f.mirror!)
        statuses.value = [0, -50]
        f.vm.signOut()
        try assertTrue((try f.kc.readSession()) == memberA && f.store.loadBookings(for: memberA)?.bookedIds == [705] && widget.loadBookedIds() == [705]
                       && f.vm.memberSession == memberA && f.vm.bookings?.bookedIds == [705] && (f.vm.bannerMessage ?? "").hasPrefix("Could not sign out"),
                       "BUG 4: a failed manual sign-out keeps the credential, primary bookings, widget mirror, and menu bookings valid (\(f.vm.bannerMessage ?? "nil"))")
        // BUG 5: a 401 refresh whose delete fails invalidates the primary bookings even though the read-only widget folder
        // keeps its copy; other surfaces are notified and the banner names the cleanup failure.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.mirror!.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.mirror!.path) }
        f.mock.classesStatus.value["tok_A"] = 401; f.mock.classesDelay.value["tok_A"] = 0.3
        drain(f.mock.classesArrived)
        let before = notes.value
        let running = Task { await f.vm.load(forceRefresh: true) }
        _ = await waitFor(f.mock.classesArrived)
        statuses.value = [0, -50]
        await running.value
        let banner = f.vm.bannerMessage ?? ""
        try assertTrue(f.store.loadBookings(for: memberA) == nil && f.vm.bookings == nil && notes.value - before >= 1 && banner.contains("Clearing cached bookings also failed"),
                       "BUG 5: the primary bookings are invalid, \(notes.value - before) notification(s) sent, and the banner names the widget cleanup failure (\(banner))")
    }

    // BUG 6 and BUG 7: sync counters.
    do {
        let f = try ctx.freshVM("l10-counters", seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, [booked(706, isoUTC(farSlot.start))]) })
        let account = f.dir.appendingPathComponent("account.json")
        func marker() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: account)) as? [String: Any] ?? [:] }
        // BUG 7: a replayed (already committed) request number and an unissued one never change bookings or the revision.
        let started = try f.store.beginBookingsSync(for: memberA, keychain: f.kc)
        _ = try f.store.commitSyncedBookings([booked(707, isoUTC(farSlot.start))], for: memberA, started: started, keychain: f.kc)
        let revision = try marker()["revision"] as? UInt64, issued = try marker()["lastIssuedSyncSeq"] as? UInt64 ?? 0
        let replay = try f.store.commitSyncedBookings([booked(708, isoUTC(farSlot.start))], for: memberA, started: started, keychain: f.kc).snapshot.bookedIds
        let unissued = denial { _ = try f.store.commitSyncedBookings([booked(709, isoUTC(farSlot.start))], for: memberA, startedAtRevision: started.startedAtRevision,
                                                                     syncSeq: issued + 1, keychain: f.kc) }
        try assertTrue(replay == [707] && !unissued.isEmpty && f.store.loadBookings(for: memberA)?.bookedIds == [707] && (try marker()["revision"] as? UInt64) == revision,
                       "BUG 7: a replayed and an unissued request number are refused; bookings and revision unchanged (\(replay) | \(unissued))")
        // BUG 6: only `revision` at its limit (no sync issued yet): a sign-in fails before touching the credential or files,
        // and a bookings sync fails before any GET without issuing a request number.
        var text = try String(contentsOf: account, encoding: .utf8)
        for (key, value) in [("revision", String(UInt64.max)), ("lastIssuedSyncSeq", "0")] {
            text = text.replacingOccurrences(of: "\"\(key)\":[0-9]+", with: "\"\(key)\":\(value)", options: .regularExpression)
        }
        try text.write(to: account, atomically: true, encoding: .utf8)
        let files = try ["account.json", "bookings.json"].map { try Data(contentsOf: f.dir.appendingPathComponent($0)) }
        let login = await denialAsync {
            let begun = try f.store.beginLogin(keychain: f.kc)
            _ = try f.store.commitLogin(memberB, attempt: begun.attempt, keychain: f.kc)
        }
        let before = f.mock.count
        let sync = await denialAsync { _ = try await f.mock.client.syncBookings(for: memberA, store: f.store, keychain: f.kc) }
        try assertTrue(!login.isEmpty && (try f.kc.readSession()) == memberA && (try ["account.json", "bookings.json"].map { try Data(contentsOf: f.dir.appendingPathComponent($0)) }) == files
                       && !sync.isEmpty && f.mock.count == before && (try marker()["lastIssuedSyncSeq"] as? UInt64) == 0,
                       "BUG 6: with only the revision exhausted, sign-in and sync fail with the credential and files untouched, 0 GETs, and no request number issued (\(login) | \(sync))")
    }

    // BUG 8: at 10:00 a started 09:00 Canary Wharf booking of class 501 never hides Wood Wharf's 16:00 class 501.
    do {
        let ten = clock(todayIso, "10:00"), woodRow = wood(501, todayIso, "16:00")
        let f = try ctx.freshVM("l10-matched", seed: { st, kc, _, _ in
            try loginSeed(st, memberA, kc, [booked(501, isoUTC(clock(todayIso, "09:00")))])
            try st.seedSnapshot(clubSnapshot([todayIso: [woodRow]], clubId: 200))
            try st.seedPreferences(TertiaPreferences(clubId: 200, clubName: "Wood Wharf", clubShortCode: "WW"))
        })
        f.vm.selectedDate = todayIso
        try assertTrue(f.vm.filteredClasses(now: ten).map(\.id) == [501],
                       "BUG 8: the Wood Wharf 16:00 row stays listed at 10:00 despite the started Canary Wharf booking of its ID")
    }

    // BUG 9: widget badges bound to the booked row: a wrong club, a reused ID on another date (also past midnight), and an
    // unlistable widget folder each show 0 badges in every size.
    do {
        func widgetCase(_ name: String, prefs: Club, rows: [Int: [String: [ClassSession]]], booking: MemberBooking) throws -> (store: SharedStateStore, mirror: URL) {
            let dir = ctx.scratch(name), mdir = ctx.scratch(name + "-widget"), kcW = ctx.keychain(name)
            for folder in [dir, mdir] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir)
            for (club, days) in rows { try st.seedSnapshot(clubSnapshot(days, clubId: club)) }
            try st.seedPreferences(TertiaPreferences(clubId: prefs.id, clubName: prefs.name, clubShortCode: prefs.shortCode))
            try loginSeed(st, memberA, kcW, [booking])
            return (SharedStateStore(primaryDirectory: mdir), mdir)
        }
        func badges(_ state: WidgetState, now: Date) -> [Set<Int>] {
            [TertiaSmallWidgetView(snapshot: state.snapshot, preferences: state.preferences, bookedIds: [501], rowTokens: state.rowTokens, now: now).bookedIds,
             TertiaMediumWidgetView(snapshot: state.snapshot, preferences: state.preferences, bookedIds: [501], rowTokens: state.rowTokens, now: now).bookedIds,
             TertiaLargeWidgetView(snapshot: state.snapshot, preferences: state.preferences, bookedIds: [501], rowTokens: state.rowTokens, now: now).bookedIds]
        }
        let late = clock(todayIso, "23:50"), afterMidnight = clock(tomorrowIso, "00:10"), todayBooking = booked(501, isoUTC(clock(todayIso, "23:55")))
        let wrongClub = try widgetCase("l10-widget-club", prefs: woodWharf, rows: [200: [todayIso: [wood(501, todayIso, "23:55")]]], booking: todayBooking)
        let wrongClubState = loadWidgetState(store: wrongClub.store, now: late)
        let laterDay = try widgetCase("l10-widget-day", prefs: canary, rows: [39: [tomorrowIso: [row(501, tomorrowIso, "07:00")]]], booking: todayBooking)
        let laterStates = [late, afterMidnight].map { loadWidgetState(store: laterDay.store, now: $0) }
        let entries = widgetTimelineDates(snapshot: laterStates[0].snapshot, preferences: laterStates[0].preferences, now: late)
        let unlisted = try widgetCase("l10-widget-list", prefs: canary, rows: [39: [todayIso: [row(501, todayIso, "23:55")]]], booking: todayBooking)
        let listed = loadWidgetState(store: unlisted.store, now: late).bookedIds
        try fm.setAttributes([.posixPermissions: 0o111], ofItemAtPath: unlisted.mirror.path)
        let unlistedState = loadWidgetState(store: unlisted.store, now: late)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unlisted.mirror.path)
        let midnightEntry = entries.contains(LondonCalendar.nextMidnight(after: late)!)
        try assertTrue(wrongClubState.bookedIds.isEmpty && badges(wrongClubState, now: late).allSatisfy(\.isEmpty)
                       && laterStates.allSatisfy { $0.bookedIds.isEmpty && badges($0, now: afterMidnight).allSatisfy(\.isEmpty) } && midnightEntry
                       && listed == [501] && unlistedState.bookedIds.isEmpty && unlistedState.preferences.clubId == 39,
                       "BUG 9: 0 badges for a wrong-club row, a reused ID tomorrow (before and after the midnight entry), and an unlistable widget folder (control: \(listed))")
    }

    // BUG 10: a day switch while a Book waits on .mutation.lock refuses it under the lock (0 mutations); date pills are
    // locked meanwhile.
    do {
        let r = row(710, openSlot.date, openSlot.time)
        let f = try ctx.freshVM("l10-day", seed: { st, kc, _, _ in try loginSeed(st, memberA, kc, []); try st.seedSnapshot(clubSnapshot([openSlot.date: [r]])) })
        let lock = try await holdMutationLock(f.dir), before = f.mock.count
        let queued = Task { try await click(f.vm, r) }
        for _ in 0..<1000 where f.vm.busyClassId != 710 { await Task.yield() }
        let locked = f.vm.isDaySwitchLocked
        f.vm.selectDate(LondonCalendar.addDays(to: openSlot.date, days: 1)!)
        lock.release.signal()
        try await queued.value
        _ = try? await lock.task.value
        try assertTrue(locked && f.mock.actions(after: before).isEmpty && f.vm.bannerMessage == stale && !f.vm.isDaySwitchLocked,
                       "BUG 10: a day switch made while the Book waits on .mutation.lock sends 0 mutations (\(f.vm.bannerMessage ?? "nil"))")
    }

    // BUG 11 and SIMPLIFY 26: one render index decodes each entitled club's timetable once for every card; a stored row
    // retitled or moved behind the loaded one disables its card (Book, and Cancel of an undated booking), and a
    // pre-dispatch edit is still caught by the dispatch's own disk read.
    do {
        let reads = Locked(0), book = row(711, openSlot.date, openSlot.time, "Ride"), undated = row(712, farSlot.date, farSlot.time, "Pump"), other = row(713, openSlot.date, openSlot.time, "Spin")
        let dir = ctx.scratch("l10-index"), kcI = ctx.keychain("l10-index"), mock = MobileMock()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let st = SharedStateStore(primaryDirectory: dir, betweenClubSnapshotReads: { _ in reads.mutate { $0 += 1 } })
        try loginSeed(st, memberA, kcI, [booked(712, "")])
        try st.seedSnapshot(clubSnapshot([openSlot.date: [book, other], farSlot.date: [undated]]))
        try st.seedSnapshot(clubSnapshot([openSlot.date: []], clubId: 200))
        let vm = ScheduleViewModel(store: st, keychain: kcI, client: mockPublicClient(store: st), bookingClient: mock.client)
        let start = reads.value, index = vm.entitledTimetableIndex()
        let drawn = [book, undated, other].map { vm.classAction(for: $0, index: index) != nil }
        let decoded = reads.value - start
        let action = vm.classAction(for: book, index: index)
        func retitled(_ rows: [ClassSession]) -> [ClassSession] { rows.map { ClassSession(id: $0.id, date: $0.date, startTime: $0.startTime, endTime: $0.endTime, durationMinutes: 45, title: $0.title + " (new)", trainer: "", clubName: $0.clubName) } }
        try st.seedSnapshot(clubSnapshot([openSlot.date: retitled([book]) + [other], farSlot.date: retitled([undated])]))
        let before = mock.count
        await action?()
        let moved = ClassSession(id: 711, date: openSlot.date, startTime: slot(5 * 3600 + 600).time, endTime: "23:59", durationMinutes: 45, title: "Ride", trainer: "", clubName: "Canary Wharf")
        let retitledActions = (vm.classAction(for: book), vm.classAction(for: undated), vm.classAction(for: other) != nil)
        try st.seedSnapshot(clubSnapshot([openSlot.date: [moved, other], farSlot.date: [undated]]))
        try assertTrue(decoded == 2 && drawn == [true, true, true] && mock.count == before && vm.bannerMessage == stale && retitledActions.0 == nil && retitledActions.1 == nil
                       && retitledActions.2 && vm.classAction(for: book) == nil && vm.classAction(for: undated) != nil,
                       "BUG 11 / SIMPLIFY 26: \(decoded) snapshot decodes for 3 cards; a pre-dispatch edit sends 0 requests; retitled or moved stored rows disable Book and undated Cancel")
    }

    // BUG 12: at 23:50 with only today cached, the widget refresh also fetches tomorrow (public page only), so the midnight
    // entry shows tomorrow's 00:10 class.
    do {
        let dir = ctx.scratch("l10-midnight"), st = SharedStateStore(primaryDirectory: dir), late = clock(todayIso, "23:50")
        try st.seedPreferences(TertiaPreferences(clubId: 220, clubName: "Chelsea", clubShortCode: "CHE"))
        try st.seedSnapshot(clubSnapshot([todayIso: []], clubId: 220, clubs: [canary, woodWharf, chelsea]))
        MockHTTPBox.shared.set(220, body: timetableHTML([Fx(id: 820, slot: at(tomorrowIso, "00:10"), title: "Midnight Ride", club: "Chelsea")],
                                                        emptyDays: (1...4).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) }))
        let fetches = MockHTTPBox.shared.count(220)
        let state = await refreshWidgetState(store: st, client: mockPublicClient(store: st), now: late)
        let midnight = LondonCalendar.nextMidnight(after: late)!
        try assertTrue(MockHTTPBox.shared.count(220) == fetches + 1 && widgetTimelineDates(snapshot: state.snapshot, preferences: state.preferences, now: late).contains(midnight)
                       && widgetUpcomingSessions(snapshot: state.snapshot, preferences: state.preferences, now: midnight).map(\.id) == [820],
                       "BUG 12: one public fetch of tomorrow at 23:50; the midnight entry shows the 00:10 class")
    }

    // BUG 13: a fetch sent at 23:59 and completed at 00:01 prunes by the completion clock; a clock rollback during a fetch
    // caps the day stamps (primary and widget folders) and the public-clubs.json stamp at the completion clock.
    do {
        let dir = ctx.scratch("l10-prune"), mdir = ctx.scratch("l10-prune-widget")
        for folder in [dir, mdir] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let st = SharedStateStore(primaryDirectory: dir, mirrorDirectory: mdir), dayBefore = LondonCalendar.addDays(to: todayIso, days: -1)!
        try st.seedSnapshot(clubSnapshot([dayBefore: [], todayIso: []]))
        let range = (0...3).compactMap { LondonCalendar.addDays(to: todayIso, days: $0) }
        _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [:], fetchedRange: range,
                                        requestSeq: try st.reserveSnapshotSequence(), syncedAt: clock(todayIso, "23:59"), now: clock(tomorrowIso, "00:01"))
        let pruned = st.loadSnapshot(clubId: 39)?.days.keys.sorted() ?? []
        let completed = Date(), requested = completed.addingTimeInterval(3600)
        _ = try st.mergeAndSaveSnapshot(clubId: 39, clubs: [canary], clubName: "Canary Wharf", clubShortCode: "CANARY", fetchedDays: [:], fetchedRange: [todayIso],
                                        requestSeq: try st.reserveSnapshotSequence(), syncedAt: requested, now: completed)
        func stamps(_ folder: URL) -> [Date] {
            let snap = SharedStateStore(primaryDirectory: folder).loadSnapshot(clubId: 39)
            // Only the primary folder keeps public-clubs.json; the widget folder holds snapshot copies.
            let clubs = (try? Data(contentsOf: folder.appendingPathComponent("public-clubs.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let clubsAt = (clubs?["updatedAt"] as? String).flatMap { raw -> Date? in
                let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return fmt.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
            }
            return [snap?.syncedAt(for: todayIso), clubsAt].compactMap { $0 }
        }
        let capped = [dir, mdir].flatMap(stamps)
        try assertTrue(pruned == range && capped.count == 3 && capped.allSatisfy { $0 <= completed.addingTimeInterval(0.001) },
                       "BUG 13: completion-clock pruning (\(pruned)); rollback stamps capped at completion in both folders (\(capped.count) stamps)")
    }

    // BUG 14 and BUG 15: comments in every declaration gap, comment decoys, and one-pass entity decoding.
    do {
        let page = timetableHTML([Fx(id: 830, slot: at(todayIso, "10:00"), title: "Gap Ride")])
            .replacingOccurrences(of: "let clubs = ", with: "/* let clubs = [{\"id\":1}]; */ let /*1*/ clubs /*2*/ = /*3*/ ")
            .replacingOccurrences(of: "let timetable = ", with: "let //c\n timetable = ")
        let parsed = try HTMLTimetableParser.parse(html: page, clubId: 39)
        try assertTrue(parsed.clubs.map(\.id).contains(39) && !parsed.clubs.map(\.id).contains(1) && parsed.days[todayIso]?.map(\.id) == [830]
                       && HTMLTimetableParser.decodeHTMLEntities("A&nbsp;B") == "A B" && HTMLTimetableParser.decodeHTMLEntities("A&amp;nbsp;B") == "A&nbsp;B",
                       "BUG 14 / 15: declarations with comments in every gap parse (decoy ignored); entities decode once")
    }

    // BUG 16, 17, 18: bundle-guarded publishing, custom destination locks, and the build lock.
    do {
        let pubRoot = ctx.scratch("l10-publish"), sentinel = "KEEP"
        func bundle(_ path: String, identifier: String? = "club.tertia.macos", marker: String) throws -> URL {
            let url = pubRoot.appendingPathComponent(path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if let identifier { try markTertiaBundle(url, identifier: identifier) }
            try marker.write(to: url.appendingPathComponent(sentinel), atomically: true, encoding: .utf8)
            return url
        }
        func kept(_ url: URL, _ marker: String) -> Bool { (try? String(contentsOf: url.appendingPathComponent(sentinel), encoding: .utf8)) == marker }
        func swap(_ stage: URL, _ dest: URL) throws -> Int32 { try runSubprocess("/usr/bin/python3", args: ["-I", publish, "swap", stage.path, dest.path], timeoutSeconds: 10).status }
        let foreign = try bundle("Foreign.app", identifier: "com.example.other", marker: "foreign"), folder = try bundle("Folder", identifier: nil, marker: "folder")
        let genuine = try bundle("Tertia.app", marker: "old")
        let stage1 = try bundle(".Tertia.app.stage.1", marker: "new"), stage2 = try bundle(".Tertia.app.stage.2", marker: "new"), stage3 = try bundle(".Tertia.app.stage.3", marker: "new")
        let swaps = [try swap(stage1, foreign), try swap(stage2, folder), try swap(stage3, genuine)]
        let rawAppBin = ProcessInfo.processInfo.environment["TERTIA_APP_BIN"].flatMap { $0.isEmpty ? nil : $0 } ?? "dist/Tertia.app/Contents/MacOS/Tertia"
        let appBundle = URL(fileURLWithPath: rawAppBin.hasPrefix("/") ? rawAppBin : root.appendingPathComponent(rawAppBin).path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let install = try runSubprocess("/usr/bin/make", args: ["-C", root.path, "--no-print-directory", "-o", "package", "install", "INSTALL_APP=\(foreign.path)", "TERTIA_DIST_APP=\(appBundle.path)",
                                                               "LSREGISTER=/usr/bin/true", "PLUGINKIT=/usr/bin/true"], timeoutSeconds: 30)
        let mkRoot = ctx.scratch("l10-clean")
        try fm.createDirectory(at: mkRoot.appendingPathComponent("Scripts"), withIntermediateDirectories: true)
        for path in ["Makefile", "Scripts/publish.py"] { try fm.copyItem(at: root.appendingPathComponent(path), to: mkRoot.appendingPathComponent(path)) }
        try fm.createDirectory(at: mkRoot.appendingPathComponent(".build/direct"), withIntermediateDirectories: true)
        _ = fm.createFile(atPath: mkRoot.appendingPathComponent(".build/direct/TertiaApp").path, contents: Data())
        func clean(_ distApp: String) throws -> Int32 {
            try runSubprocess("/usr/bin/make", args: ["-C", mkRoot.path, "--no-print-directory", "clean", "TERTIA_DIST_APP=\(distApp)"],
                              env: ["PATH": "/usr/bin:/bin", "TERTIA_LOCK_TIMEOUT": "0.3"], timeoutSeconds: 10).status
        }
        let refusedCleans = [try clean(foreign.path), try clean(folder.path)]
        let output = mkRoot.appendingPathComponent(".build/direct/TertiaApp")
        try assertTrue(swaps == [1, 1, 0] && kept(foreign, "foreign") && kept(folder, "folder") && kept(genuine, "new") && kept(stage1, "new") && install.status != 0 && kept(foreign, "foreign")
                       && refusedCleans.allSatisfy { $0 != 0 } && fm.fileExists(atPath: output.path) && kept(foreign, "foreign") && kept(folder, "folder"),
                       "BUG 16: swap, make install, and make clean refuse a foreign .app and a plain folder (sentinels kept); a genuine Tertia bundle is replaced (\(swaps))")
        // BUG 17: a held custom destination lock under dist makes `make clean` time out with output, stage, and lock intact.
        let probe = Process(); probe.executableURL = URL(fileURLWithPath: "/usr/bin/true"); try probe.run(); probe.waitUntilExit()
        for sub in ["dist", "dist/sub"] {
            let custom = mkRoot.appendingPathComponent("\(sub)/Custom.app"), stage = mkRoot.appendingPathComponent("\(sub)/.Custom.app.stage.\(probe.processIdentifier)")
            let lockFile = mkRoot.appendingPathComponent("\(sub)/.Custom.app.lock")
            try markTertiaBundle(custom); try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            _ = fm.createFile(atPath: lockFile.path, contents: Data())
            let fd = open(lockFile.path, O_RDWR); flock(fd, LOCK_EX)
            let status = try clean(custom.path)
            flock(fd, LOCK_UN); close(fd)
            try assertTrue(status != 0 && [custom, stage, lockFile, output].allSatisfy { fm.fileExists(atPath: $0.path) },
                           "BUG 17: a held \(sub)/.Custom.app.lock makes make clean time out; output, stage, and lock are intact")
        }
        // BUG 18: build.sh waiting on .build/.build.lock creates .build/direct only after it holds the lock.
        let buildRoot = ctx.scratch("l10-build"), probeFile = buildRoot.appendingPathComponent("saw-direct")
        for dir in ["Scripts", "fake-bin", ".build"] { try fm.createDirectory(at: buildRoot.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["Scripts/build.sh", "Scripts/publish.py"] { try fm.copyItem(at: root.appendingPathComponent(path), to: buildRoot.appendingPathComponent(path)) }
        let direct = buildRoot.appendingPathComponent(".build/direct")
        for (path, text) in [("fake-bin/xcrun", "#!/bin/sh\necho /tmp\n"), ("fake-bin/swiftc", "#!/bin/sh\n[ -d '\(direct.path)' ] && : > '\(probeFile.path)'\nexit 0\n")] {
            try text.write(to: buildRoot.appendingPathComponent(path), atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: buildRoot.appendingPathComponent(path).path)
        }
        let buildLock = buildRoot.appendingPathComponent(".build/.build.lock")
        _ = fm.createFile(atPath: buildLock.path, contents: Data())
        let fd = open(buildLock.path, O_RDWR); flock(fd, LOCK_EX)
        let build = Task.detached {
            try? runSubprocess("/bin/bash", args: [buildRoot.appendingPathComponent("Scripts/build.sh").path], env: ["PATH": "\(buildRoot.appendingPathComponent("fake-bin").path):/usr/bin:/bin", "TERTIA_BUILD_DIR": ""], timeoutSeconds: 15)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let earlyDirect = fm.fileExists(atPath: direct.path)
        flock(fd, LOCK_UN); close(fd)
        let built = await build.value
        try assertTrue(!earlyDirect && built?.status == 0 && built?.timedOut == false && fm.fileExists(atPath: direct.path) && fm.fileExists(atPath: probeFile.path),
                       "BUG 18: build.sh waits on .build/.build.lock before creating .build/direct, then builds (\(built?.stderr.suffix(200) ?? "nil"))")
    }

    // BUG 19 and BUG 20: bounded password input and the login's future-class count.
    do {
        func read(_ input: String) -> String? {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(input.utf8)); try? pipe.fileHandleForWriting.close()
            return try? TertiaCLI.readBoundedPasswordStdin(from: pipe.fileHandleForReading)
        }
        let long = String(repeating: "x", count: 4097), exact = String(repeating: "x", count: 4096)
        let parsed = [read("pw\n"), read("pw\r\n"), read("pw"), read(exact + "\n"), read(long)]
        let f = try ctx.freshVM("l10-login")
        let before = f.mock.count
        let rejected = try await withStdin(ctx, Data((long + "\n").utf8)) {
            try await captureOutput(fd: STDERR_FILENO) { await TertiaCLI.run(args: ["login", "--email", "a@example.com", "--password-stdin"], store: f.store, keychain: f.kc, bookingClient: f.mock.client) }
        }
        try assertTrue(parsed == ["pw", "pw", "pw", exact, nil] && rejected.code != 0 && rejected.out.contains("exceeds maximum length") && f.mock.count == before && (try f.kc.readSession()) == nil,
                       "BUG 19: LF, CRLF, and bare passwords are read; >4096 bytes is refused before any sign-in step")
        let starting = Date().addingTimeInterval(0.3)
        f.mock.bookings.value["tok_A"] = classesJSON([(840, isoUTC(starting)), (841, isoUTC(farSlot.start))])
        f.mock.classesDelay.value["tok_A"] = 0.6
        let login = try await withStdin(ctx, Data("pw\n".utf8)) {
            try await captureOutput { await TertiaCLI.run(args: ["login", "--email", "a@example.com", "--password-stdin"], store: f.store, keychain: f.kc,
                                                          client: mockPublicClient(store: f.store), bookingClient: f.mock.client) }
        }
        try assertTrue(login.code == 0 && login.out.contains("Synced 1 future classes"), "BUG 20: a class that starts during the login sync is not counted (\(login.out))")
    }

    // BUG 24 and BUG 25: self-test isolation names the exact store; harness scratch folders and Keychain services are
    // registered with test.sh's cleanup before they exist, and that cleanup removes a killed fixture's leftovers.
    do {
        let storeDir = ctx.scratch("l10-selftest"), service = "club.tertia.macos.selftest.\(UUID().uuidString)"
        let model = ScheduleViewModel(store: SharedStateStore(primaryDirectory: storeDir), keychain: KeychainStore(service: service, account: "verify"),
                                      client: mockPublicClient(store: SharedStateStore(primaryDirectory: storeDir)), bookingClient: MobileMock().client)
        let isolation = (ScheduleViewModel.verifySelfTestIsolation(model: model, expectedStoreDirectory: storeDir),
                         ScheduleViewModel.verifySelfTestIsolation(model: model, expectedStoreDirectory: ctx.scratch("l10-selftest-other")))
        let env = ProcessInfo.processInfo.environment
        let scratchRoot = env["TERTIA_TEST_SCRATCH_ROOT"] ?? "", keychainLog = env["TERTIA_TEST_KEYCHAIN_LOG"] ?? ""
        let fresh = ctx.keychainService("l10-logged")
        let logged = (try? String(contentsOfFile: keychainLog, encoding: .utf8))?.contains(fresh + "\n") == true
        let unseeded = try runSubprocess("/usr/bin/security", args: ["find-generic-password", "-s", fresh], timeoutSeconds: 5).status != 0
        // A child fixture registers its scratch folder and Keychain item the same way, then is killed; test.sh's own
        // cleanup function (run from a copy of a fake test build) removes both.
        let fakeBuild = ctx.scratch("l10-test-build"), childService = "club.tertia.macos.test.l10-child.\(UUID().uuidString)"
        let cleanupFn = try String(contentsOf: root.appendingPathComponent("Scripts/test.sh"), encoding: .utf8)
            .components(separatedBy: "\n").drop { !$0.hasPrefix("cleanup_test_run() {") }.prefix { $0 != "}" }.joined(separator: "\n") + "\n}\n"
        let child = "set -e\nmkdir -p \"$TERTIA_TEST_SCRATCH_ROOT/tertia-child\"\necho \"$SVC\" >> \"$TERTIA_TEST_KEYCHAIN_LOG\"\n"
            + "/usr/bin/security add-generic-password -s \"$SVC\" -a verify -w x\nkill -9 $$\n"
        let childEnv = ["TEST_BUILD": fakeBuild.path, "TERTIA_TEST_SCRATCH_ROOT": fakeBuild.appendingPathComponent("scratch").path,
                        "TERTIA_TEST_KEYCHAIN_LOG": fakeBuild.appendingPathComponent("keychain-services.txt").path, "SVC": childService]
        try fm.createDirectory(at: fakeBuild.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        let killed = try runSubprocess("/bin/bash", args: ["-c", child], env: childEnv, timeoutSeconds: 10)
        let leftBehind = fm.fileExists(atPath: fakeBuild.appendingPathComponent("scratch/tertia-child").path)
        let cleaned = try runSubprocess("/bin/bash", args: ["-c", cleanupFn + "cleanup_test_run\n"], env: childEnv, timeoutSeconds: 10)
        let itemGone = try runSubprocess("/usr/bin/security", args: ["find-generic-password", "-s", childService], timeoutSeconds: 5).status != 0
        try assertTrue(isolation == (true, false) && !scratchRoot.isEmpty && storeDir.path.hasPrefix(scratchRoot) && logged && unseeded
                       && killed.status == SIGKILL && leftBehind && cleaned.status == 0 && !fm.fileExists(atPath: fakeBuild.path) && itemGone,
                       "BUG 24 / 25: isolation rejects a mismatched store; scratch and Keychain services are pre-registered; test.sh cleanup removes a killed fixture's folder and item")
    }

    // ACL-rejected Keychain reads (-25293, -25308, -25244) report concise plain-English copy in both KeychainError and
    // ScheduleViewModel while non-ACL errors keep their OSStatus detail; package_app.sh auto-selects Apple Development or
    // Developer ID Application identities and falls back to ad-hoc "-" otherwise.
    do {
        for code: Int32 in [-25293, -25308, -25244] {
            let err = KeychainError.osStatus(code)
            try assertTrue(err.isACLRejection && err.localizedDescription == "App updated. Sign in again to reconnect Keychain.", "ACL status \(code) maps to plain update prompt")
            let stACL = SharedStateStore(primaryDirectory: ctx.scratch("l10-acl-\(abs(code))"))
            let kcACL = KeychainStore(service: ctx.keychainService("l10-acl-\(abs(code))"), account: "verify", hooks: .init(statusOverride: code))
            let vmACL = ScheduleViewModel(store: stACL, keychain: kcACL, client: mockPublicClient(store: stACL), bookingClient: MobileMock().client)
            try assertEqual(vmACL.bannerMessage, "App updated. Sign in again to reconnect Keychain.", "ACL status \(code) renders concise banner in ScheduleViewModel")
        }
        let nonACL = KeychainError.osStatus(-50)
        try assertTrue(!nonACL.isACLRejection && nonACL.localizedDescription == "macOS Keychain error (OSStatus -50).", "non-ACL OSStatus keeps exact code")
        let st = SharedStateStore(primaryDirectory: ctx.scratch("l10-nonacl"))
        let kc50 = KeychainStore(service: ctx.keychainService("l10-nonacl"), account: "verify", hooks: .init(statusOverride: -50))
        let vm50 = ScheduleViewModel(store: st, keychain: kc50, client: mockPublicClient(store: st), bookingClient: MobileMock().client)
        try assertEqual(vm50.bannerMessage, "Saved sign-in unreadable (macOS Keychain error (OSStatus -50)). Sign in again.", "non-ACL Keychain error keeps full diagnostic banner")
        let pkgScript = try String(contentsOf: root.appendingPathComponent("Scripts/package_app.sh"), encoding: .utf8)
        try assertTrue(pkgScript.contains("Developer ID Application|Apple Development") && pkgScript.contains("SIGN_IDENTITY=\"${APPLE_IDENTITY:--}\""), "package_app.sh selects Apple TeamIdentifier signing identities or falls back to ad-hoc")
    }

    // Zero past grace across MenuBar, empty-state copy, and CLI: unbooked classes leave at exact start with zero extra
    // public or private requests (redraws are driven locally by upcomingBoundaryDates).
    do {
        let f = try ctx.freshVM("l10-zero-grace")
        let at095959 = clock(todayIso, "09:59").addingTimeInterval(59), at1000 = clock(todayIso, "10:00"), at1005 = clock(todayIso, "10:05"), at1015 = clock(todayIso, "10:15"), at1100 = clock(todayIso, "11:00")
        let tenAM = row(991, todayIso, "10:00"), elevenAM = row(992, todayIso, "11:00")
        f.vm.snapshot = clubSnapshot([todayIso: [tenAM, elevenAM]])
        f.vm.selectedDate = todayIso
        let pubBefore = MockHTTPBox.shared.count(39), privBefore = f.mock.count
        let boundaries = f.vm.upcomingBoundaryDates(now: at095959)
        try assertTrue(f.vm.filteredClasses(now: at095959).map(\.id) == [991, 992] && boundaries.contains(at1000) && !boundaries.contains(at1015)
                       && f.vm.filteredClasses(now: at1000).map(\.id) == [992] && f.vm.filteredClasses(now: at1005).map(\.id) == [992],
                       "menu drops unbooked class 991 at exact start 10:00 and schedules boundary at 10:00 (not 10:15)")
        f.vm.preferences.searchQuery = "zzz"
        try assertTrue(f.vm.emptyScheduleMessage(now: at1000) == "No classes match this filter." && f.vm.emptyScheduleMessage(now: at1100) == "No more classes today."
                       && MockHTTPBox.shared.count(39) == pubBefore && f.mock.count == privBefore,
                       "empty-state copy updates at exact class start 11:00 with zero public or private API calls")
        let cliStore = SharedStateStore(primaryDirectory: ctx.scratch("l10-zero-grace-cli"))
        MockHTTPBox.shared.set(39, body: timetableHTML([Fx(id: 991, slot: Slot(date: todayIso, time: "10:00", start: at1000), title: "Ten"),
                                                       Fx(id: 992, slot: Slot(date: todayIso, time: "11:00", start: at1100), title: "Eleven")], emptyDays: [todayIso]))
        let queried = try await TertiaCLI.queryTimetable(clubId: 39, date: todayIso, period: nil, search: nil, refresh: true, store: cliStore, client: mockPublicClient(store: cliStore), nowProvider: { @Sendable in at1000 })
        MockHTTPBox.shared.set(39, body: page39)
        try assertEqual(queried.classes.map(\.id), [992], "CLI explicit --date today also drops started classes at start time")
    }
}
