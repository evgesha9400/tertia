import Foundation
#if canImport(Security)
import Security
#endif

public enum KeychainError: Error, LocalizedError, Sendable, Equatable {
    case osStatus(Int32)
    case invalidData
    case unsupportedPlatform
    /// An unreadable item was deleted to make room for a new session, and then saving the new session failed;
    /// `cleanupError` reports a failed local account-file cleanup that followed.
    case previousSessionLost(Int32, cleanupError: String? = nil)
    /// The Keychain operation completed, but restoring the previous Keychain UI setting failed (a warning, never a failure).
    case interactionRestoreFailed(Int32)

    public var isACLRejection: Bool {
        #if canImport(Security)
        if case .osStatus(let code) = self { return KeychainStore.isACLRejection(code) }
        #endif
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .osStatus(let code):
            #if canImport(Security)
            if KeychainStore.isACLRejection(code) { return "App updated. Sign in again to reconnect Keychain." }
            #endif
            return "macOS Keychain error (OSStatus \(code))."
        case .invalidData: return "The saved Tertia Keychain session is unreadable. Sign in again to replace it."
        case .unsupportedPlatform: return "Keychain storage requires a platform credential store implementation on this OS."
        case .previousSessionLost(let code, let cleanupError):
            return "Removed unreadable Keychain item, but saving the new session failed (OSStatus \(code)). Please sign in again."
                + (cleanupError.map { " Clearing local account files also failed: \($0)" } ?? "")
        case .interactionRestoreFailed(let code): return "Restoring the macOS Keychain interaction setting failed (OSStatus \(code))."
        }
    }
}

#if canImport(Security) && os(macOS)
@_silgen_name("SecKeychainGetUserInteractionAllowed")
private func tertiaGetKeychainInteractionAllowed(_ state: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus

@_silgen_name("SecKeychainSetUserInteractionAllowed")
private func tertiaSetKeychainInteractionAllowed(_ state: DarwinBoolean) -> OSStatus
#endif

/// Stores the authenticated member session in the user's macOS login Keychain
/// without restricted entitlements so ad-hoc open-source builds run out of the box.
public struct KeychainStore: Sendable {
    /// System seams; tests replace them to simulate interaction-suppression failures, transient errors, or a hung helper.
    public struct Hooks: Sendable {
        public var getInteractionAllowed: @Sendable () -> (status: Int32, allowed: Bool)
        public var setInteractionAllowed: @Sendable (Bool) -> Int32
        /// When set, every `SecItem*` call reports this status instead of touching the Keychain.
        public var statusOverride: Int32?
        public var securityToolPath: String

        public init(getInteractionAllowed: @escaping @Sendable () -> (status: Int32, allowed: Bool) = Hooks.live.getInteractionAllowed,
                    setInteractionAllowed: @escaping @Sendable (Bool) -> Int32 = Hooks.live.setInteractionAllowed,
                    statusOverride: Int32? = nil, securityToolPath: String = "/usr/bin/security") {
            self.getInteractionAllowed = getInteractionAllowed; self.setInteractionAllowed = setInteractionAllowed
            self.statusOverride = statusOverride; self.securityToolPath = securityToolPath
        }

        #if canImport(Security) && os(macOS)
        public static let live = Hooks(
            getInteractionAllowed: { var state: DarwinBoolean = true; let status = tertiaGetKeychainInteractionAllowed(&state); return (status, state.boolValue) },
            setInteractionAllowed: { tertiaSetKeychainInteractionAllowed(DarwinBoolean($0)) })
        #else
        public static let live = Hooks(getInteractionAllowed: { (0, true) }, setInteractionAllowed: { _ in 0 })
        #endif
    }

    public let service, account: String
    private let hooks: Hooks
    #if canImport(Security) && os(macOS)
    private static let uiLock = NSLock()
    #endif

    public init(service: String = "club.tertia.macos", account: String = "member-session", hooks: Hooks = .live) {
        self.service = service; self.account = account; self.hooks = hooks
    }

    #if canImport(Security)
    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Runs a `SecItem*` call with Keychain UI disabled; throws before the call when UI cannot be disabled. The call's
    /// status is captured first; a failed restore of the previous UI setting is recorded in `warning`, never thrown, so a
    /// completed credential write or delete is never reported (or retried) as failed.
    private func withoutUI(_ warning: inout KeychainError?, _ body: () -> OSStatus) throws -> OSStatus {
        #if os(macOS)
        Self.uiLock.lock(); defer { Self.uiLock.unlock() }
        let (getStatus, previous) = hooks.getInteractionAllowed()
        guard getStatus == errSecSuccess else { throw KeychainError.osStatus(getStatus) }
        let setStatus = hooks.setInteractionAllowed(false)
        guard setStatus == errSecSuccess else { throw KeychainError.osStatus(setStatus) }
        let status = hooks.statusOverride ?? body()
        let restoreStatus = hooks.setInteractionAllowed(previous)
        if restoreStatus != errSecSuccess, warning == nil { warning = .interactionRestoreFailed(restoreStatus) }
        return status
        #else
        return hooks.statusOverride ?? body()
        #endif
    }

    private func copyData(_ warning: inout KeychainError?) throws -> (status: OSStatus, data: Data?) {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = try withoutUI(&warning) { SecItemCopyMatching(query as CFDictionary, &item) }
        return (status, item as? Data)
    }

    /// Another binary's ACL, CDHash, or ownership (`SecItemDelete` on an item created by `/usr/bin/security` reports
    /// `errSecInvalidOwnerEdit`); only these justify delete-and-replace and the `security` fallback.
    fileprivate static func isACLRejection(_ status: OSStatus) -> Bool { [errSecInteractionNotAllowed, errSecAuthFailed, errSecInvalidOwnerEdit].contains(status) }

    /// Updates a readable item in place and adds a missing one. An ACL-rejected item is deleted and re-added (a failed
    /// re-add then throws `.previousSessionLost`); any other failure throws and leaves the existing item untouched.
    /// Returns `.interactionRestoreFailed` as a warning when the save completed but the UI setting was not restored.
    @discardableResult
    public func saveSession(_ session: MemberSession) throws -> KeychainError? {
        var warning: KeychainError?
        let data = try JSONEncoder().encode(session)
        let found = try copyData(&warning).status
        var status = found == errSecSuccess ? try withoutUI(&warning) { SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary) } : found
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        if Self.isACLRejection(status) {
            if let deleteWarning = try deleteSession(), warning == nil { warning = deleteWarning }
            // The old item is gone: every later failure (UI suppression or `SecItemAdd`) reports `.previousSessionLost`.
            do { status = try withoutUI(&warning) { SecItemAdd(addQuery as CFDictionary, nil) } }
            catch KeychainError.osStatus(let code) { throw KeychainError.previousSessionLost(code) }
            catch { throw KeychainError.previousSessionLost(Int32(truncatingIfNeeded: (error as NSError).code)) }
            guard status == errSecSuccess else { throw KeychainError.previousSessionLost(status) }
            return warning
        }
        if status == errSecItemNotFound { status = try withoutUI(&warning) { SecItemAdd(addQuery as CFDictionary, nil) } }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        return warning
    }

    /// Returns `nil` only when no item exists; throws for unreadable (locked, foreign ACL) or corrupt items.
    public func readSession() throws -> MemberSession? { try readSessionWithWarning().session }

    /// `readSession` plus `.interactionRestoreFailed` as a warning when the read completed but the Keychain UI setting
    /// was not restored.
    public func readSessionWithWarning() throws -> (session: MemberSession?, warning: KeychainError?) {
        var warning: KeychainError?
        let (status, data) = try copyData(&warning)
        if status == errSecItemNotFound { return (nil, warning) }
        guard status == errSecSuccess, let data else { throw KeychainError.osStatus(status) }
        do { return (try JSONDecoder().decode(MemberSession.self, from: data), warning) } catch { throw KeychainError.invalidData }
    }

    /// Only an ACL rejection falls back to `security delete-generic-password` (3 seconds, then SIGTERM and SIGKILL with
    /// bounded waits); any other status throws immediately. Returns `.interactionRestoreFailed` as a warning when the
    /// delete completed but the UI setting was not restored.
    @discardableResult
    public func deleteSession() throws -> KeychainError? {
        var warning: KeychainError?
        let status = try withoutUI(&warning) { SecItemDelete(baseQuery as CFDictionary) }
        if status == errSecSuccess || status == errSecItemNotFound { return warning }
        guard Self.isACLRejection(status) else { throw KeychainError.osStatus(status) }
        #if os(macOS)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hooks.securityToolPath)
        proc.arguments = ["delete-generic-password", "-s", service, "-a", account]
        proc.standardOutput = FileHandle.nullDevice; proc.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        try proc.run()
        if exited.wait(timeout: .now() + 3) == .timedOut {
            proc.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                guard exited.wait(timeout: .now() + 1) == .success else { throw KeychainError.osStatus(status) }
            }
        }
        proc.waitUntilExit()
        if proc.terminationReason == .exit && proc.terminationStatus == 0 { return warning }
        #endif
        throw KeychainError.osStatus(status)
    }
    #else
    @discardableResult public func saveSession(_ session: MemberSession) throws -> KeychainError? { throw KeychainError.unsupportedPlatform }
    public func readSession() throws -> MemberSession? { nil }
    public func readSessionWithWarning() throws -> (session: MemberSession?, warning: KeychainError?) { (nil, nil) }
    @discardableResult public func deleteSession() throws -> KeychainError? { nil }
    #endif
}

/// What happened when a rejected session was expired.
public enum SessionExpiryOutcome: Sendable {
    /// The Keychain token is gone; `cacheError` reports a failed local file cleanup.
    case cleared(cacheError: Error?, warning: KeychainError?)
    /// The Keychain no longer held that session (signed out, or replaced by a newer sign-in, which was left untouched).
    case superseded(warning: KeychainError?)
    /// Reading or deleting the Keychain token failed; the token may still be stored. `invalidatedCache` is set when the
    /// session matched and at least one cached-bookings invalidation step changed disk before the failed delete was
    /// reported; `cacheError` is the first of those steps that failed.
    case failed(Error, cacheError: Error? = nil, warning: KeychainError?, invalidatedCache: Bool = false)

    public var didClear: Bool { if case .cleared = self { true } else { false } }

    /// Whether this expiry changed files on disk (a clear, or a matched session whose cache was invalidated at least in
    /// part), so other surfaces must be notified.
    public var didMutateDisk: Bool {
        if case .failed(_, _, _, true) = self { return true }
        return didClear
    }

    /// A Keychain warning (such as a failed UI-setting restore) from the reads and deletes behind this outcome.
    public var warning: KeychainError? {
        switch self { case .cleared(_, let warning), .superseded(let warning), .failed(_, _, let warning, _): warning }
    }

    /// One sentence shared by CLI, MCP, and UI messages; a cache error and a Keychain warning are both named.
    public var summary: String {
        let main = switch self {
        case .cleared(let error, _):
            "The session was cleared; sign in again." + (error.map { " Removing cached bookings also failed: \($0.localizedDescription)." } ?? "")
        case .superseded: "That session was already signed out or replaced by a newer sign-in."
        case .failed(let error, let cacheError, _, _):
            "Clearing the rejected Keychain token failed: \(error.localizedDescription). Sign out and sign in again."
                + (cacheError.map { " Clearing cached bookings also failed: \($0.localizedDescription)." } ?? "")
        }
        return main + (warning.map { " \($0.localizedDescription)" } ?? "")
    }
}

/// The account state a sign-in started from (`SharedStateStore.beginLogin`): the account revision and the digest of the
/// Keychain credential (`nil` when none was stored), so `commitLogin` can refuse when either changed meanwhile.
public struct LoginAttempt: Sendable, Equatable {
    public let revision: UInt64
    public let startingTokenDigest: String?
    public init(revision: UInt64, startingTokenDigest: String?) { self.revision = revision; self.startingTokenDigest = startingTokenDigest }
}

/// What happened to the cached bookings after an accepted book or cancel whose follow-up sync failed.
public enum FollowUpCleanupOutcome: Sendable, Equatable {
    /// The cache was invalidated (and `bookings.json` removed); a Refresh is needed before another action.
    case cleared
    /// Another sign-in or a sign-out replaced the session; its files were left untouched.
    case superseded
    /// Invalidating or removing the cache failed; the message names the error.
    case failed(String)

    /// One sentence shared by CLI, MCP, and UI messages.
    public var summary: String {
        switch self {
        case .cleared: "Cached bookings were cleared; refresh bookings before another booking action."
        case .superseded: "Bookings now follow the newly signed-in account."
        case .failed(let message): "Clearing cached bookings also failed: \(message). Refresh bookings before another booking action."
        }
    }
}

/// A failed Keychain delete during sign-out, with the warning from the Keychain read that preceded it, so both are reported.
public struct SignOutError: Error, LocalizedError, Sendable {
    public let underlying: Error
    public let warning: KeychainError?
    public init(underlying: Error, warning: KeychainError?) { self.underlying = underlying; self.warning = warning }
    public var errorDescription: String? { [underlying.localizedDescription, warning?.localizedDescription].compactMap { $0 }.joined(separator: " ") }
}

public enum StoreError: Error, LocalizedError, Sendable, Equatable {
    /// Another process held the named lock file past the store's timeout.
    case lockTimedOut(String)
    /// Class IDs must be positive.
    case invalidClassId(Int)
    /// `sequence.json` already holds the largest request number.
    case sequenceExhausted
    /// The private account revision or bookings sync counter already holds its largest value.
    case revisionExhausted

    public var errorDescription: String? {
        switch self {
        case .lockTimedOut(let name): "Another Tertia process is holding \(name); try again in a moment."
        case .invalidClassId(let id): "Invalid class ID \(id)."
        case .sequenceExhausted:
            "The timetable request counter is exhausted; delete sequence.json, public-clubs.json, and snapshot-*.json in the Tertia data folder to reset it."
        case .revisionExhausted: "The account revision counter is exhausted; sign out, then delete account.json in the Tertia data folder to reset it."
        }
    }
}

/// Persists preferences, timetable snapshots, and bookings for the menu-bar app and CLI. The sandboxed WidgetKit
/// extension reads a mirror inside its own container (no App Group entitlements); the mirror receives preferences,
/// public timetable snapshots, `account.json` with an opaque owner hash, the active booked class IDs, and one-way row
/// tokens binding each to its club and London date (`widgetRowToken`).
///
/// Account state (`account.json`, `bookings.json`, and the Keychain session) changes only under one cross-process
/// lock (`.account.lock`), so login, sync, mutation, expiry, and sign-out from the app and CLI never interleave. The
/// primary `account.json` carries a revision that every account change bumps and that survives sign-out, a minimum
/// revision a refresh must have started from to commit, and `bookingsValid`, which a mutation clears before dispatch
/// so a lost reply or crash leaves the cache unusable until a Refresh succeeds. Every file lock waits at most its
/// timeout (`StoreError.lockTimedOut`), so another process can never stall the menu indefinitely.
public final class SharedStateStore: @unchecked Sendable {
    public static let stateChangedNotification = "club.tertia.stateChanged"
    public static let widgetContainerBundleId = "club.tertia.macos.widget"
    private static let folderName = "TertiaClub"
    private static let bookingsFile = "bookings.json", accountFile = "account.json", sequenceFile = "sequence.json"
    private static let preferencesFile = "preferences.json", publicClubsFile = "public-clubs.json"

    /// Widget mirror payload: active booked IDs, the opaque owner, and one-way row tokens (`widgetRowToken`) binding each
    /// badge to its club and London date (no titles, times, emails, or waitlist data). Legacy files have no `rowTokens`.
    private struct BookedIdsMirror: Codable, Equatable { let bookedIds: [Int]; let ownerId: String; let rowTokens: [String]? }

    /// One-way digest of a booked row's class ID, trimmed lowercased club name, and London date, so the widget can
    /// badge only that row without the mirror holding the booking's club or date in readable form.
    public static func widgetRowToken(classId: Int, clubName: String, dateIso: String) -> String {
        MemberSession.opaqueId("row|\(classId)|\(clubName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(dateIso)")
    }
    /// Mirror `account.json`; also decodes the primary marker. Legacy files without `bookingsValid` count as valid.
    /// `revision` is read from the primary marker only (never written to the mirror, which holds no full snapshots).
    private struct MirrorAccountMarker: Codable, Equatable {
        var ownerId: String?
        var bookingsValid: Bool
        var revision: UInt64?

        init(ownerId: String?, bookingsValid: Bool) { self.ownerId = ownerId; self.bookingsValid = bookingsValid }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
            bookingsValid = try c.decodeIfPresent(Bool.self, forKey: .bookingsValid) ?? (ownerId != nil)
            revision = try c.decodeIfPresent(UInt64.self, forKey: .revision)
        }
    }
    /// Primary `account.json`. Legacy `{revision, ownerId, tokenDigest}` or `{ownerId}` files decode (an unknown
    /// `tokenDigest` is ignored) with `minValidSyncRevision = revision`, both sync sequence numbers `0`, and
    /// `bookingsValid` set when an owner is named (the bookings file must still carry the marker's revision to be shown).
    private struct AccountMarker: Codable, Equatable {
        var revision: UInt64 = 0
        var minValidSyncRevision: UInt64 = 0
        var bookingsValid = false
        var ownerId: String?
        /// Request number of the latest bookings refresh started (`beginBookingsSync`) and of the latest one committed.
        var lastIssuedSyncSeq: UInt64 = 0
        var lastCommittedSyncSeq: UInt64 = 0

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            revision = try c.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
            minValidSyncRevision = try c.decodeIfPresent(UInt64.self, forKey: .minValidSyncRevision) ?? revision
            ownerId = try c.decodeIfPresent(String.self, forKey: .ownerId)
            bookingsValid = try c.decodeIfPresent(Bool.self, forKey: .bookingsValid) ?? (ownerId != nil)
            lastIssuedSyncSeq = try c.decodeIfPresent(UInt64.self, forKey: .lastIssuedSyncSeq) ?? 0
            lastCommittedSyncSeq = try c.decodeIfPresent(UInt64.self, forKey: .lastCommittedSyncSeq) ?? 0
        }

        var mirror: MirrorAccountMarker { MirrorAccountMarker(ownerId: ownerId, bookingsValid: bookingsValid && ownerId != nil) }

        mutating func bind(to session: MemberSession) { ownerId = session.opaqueOwnerId }

        /// Bumps the revision and makes every refresh started before this point stale; never wraps.
        mutating func advance() throws {
            let (next, overflow) = revision.addingReportingOverflow(1)
            guard !overflow else { throw StoreError.revisionExhausted }
            revision = next; minValidSyncRevision = next
        }

        /// Marks the cache invalid and advances the revision, saturating at `.max`, so an invalidation or sign-out
        /// always succeeds (a saturated marker can never commit bookings again until `account.json` is reset).
        mutating func invalidate() {
            bookingsValid = false
            revision = revision == .max ? .max : revision + 1; minValidSyncRevision = revision
        }
    }
    private struct PublicClubsRecord: Codable { let updatedAt: Date; let seq: UInt64; let clubs: [Club] }
    private struct ClubsOnly: Decodable { let clubs: [Club] }

    /// Recursive so `withAuthorizedMutationHandoff`'s `authorize` can call read-only store APIs while the account lock is held.
    private let lock = NSRecursiveLock()
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let primaryDirectory: URL
    private let mirrorDirectory: URL?
    private let mirrorIsExplicit: Bool
    /// Longest wait (monotonic clock) for the in-process lock plus a contended state lock file before `StoreError.lockTimedOut`.
    public let lockTimeout: TimeInterval
    /// Longest wait (monotonic clock) for `.mutation.lock` (another book or cancel in flight) before `StoreError.lockTimedOut`.
    public let mutationLockTimeout: TimeInterval
    /// Monotonic seconds behind every lock deadline (`systemUptime`; tests inject a clock).
    public let uptime: @Sendable () -> TimeInterval
    /// Test seam: runs inside `readConsistentWidgetState` between its two reads, with both locks held.
    private let betweenWidgetReads: (@Sendable () -> Void)?
    /// Test seam: runs inside `reconcileAccountMirror` between the account files and the mirror `preferences.json`,
    /// with `.account.lock` held in both directories.
    private let betweenAccountAndPreferences: (@Sendable () -> Void)?
    /// Test seam: runs inside `lookupEntitledClass` after each club's snapshot was read, with that club's ID.
    private let betweenClubSnapshotReads: (@Sendable (Int) -> Void)?

    /// The folder holding the primary files (preferences, timetables, and account state).
    public var primaryDirectoryURL: URL { primaryDirectory }

    /// Monotonic seconds (immune to wall-clock changes): the default clock for store locks and transport deadlines.
    public static let systemUptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    /// `primaryDirectory == nil` selects Application Support plus the default widget-container mirror (when not sandboxed).
    /// An explicit `primaryDirectory` disables the default mirror; pass `mirrorDirectory` to mirror into a chosen folder.
    public init(primaryDirectory: URL? = nil, mirrorDirectory: URL? = nil, lockTimeout: TimeInterval = 2.0, mutationLockTimeout: TimeInterval = 5.0,
                uptime: @escaping @Sendable () -> TimeInterval = SharedStateStore.systemUptime, betweenWidgetReads: (@Sendable () -> Void)? = nil,
                betweenAccountAndPreferences: (@Sendable () -> Void)? = nil, betweenClubSnapshotReads: (@Sendable (Int) -> Void)? = nil) {
        self.lockTimeout = lockTimeout; self.mutationLockTimeout = mutationLockTimeout
        self.uptime = uptime; self.betweenWidgetReads = betweenWidgetReads; self.betweenAccountAndPreferences = betweenAccountAndPreferences
        self.betweenClubSnapshotReads = betweenClubSnapshotReads
        // Millisecond dates keep sync ordering exact across a JSON round-trip; plain ISO-8601 files still decode.
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .custom { date, encoder in
            let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = encoder.singleValueContainer(); try c.encode(fmt.string(from: date))
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer(), text = try c.decode(String.self), fmt = ISO8601DateFormatter()
            for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                fmt.formatOptions = options
                if let date = fmt.date(from: text) { return date }
            }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO-8601 date '\(text)'")
        }
        self.encoder = enc; self.decoder = dec
        self.mirrorIsExplicit = mirrorDirectory != nil

        let primary: URL, mirror: URL?
        if let primaryDirectory {
            primary = primaryDirectory; mirror = mirrorDirectory
        } else {
            let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            primary = appSupport.appendingPathComponent(Self.folderName, isDirectory: true)
            #if os(macOS)
            mirror = mirrorDirectory ?? (isSandboxed ? nil : fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(Self.widgetContainerBundleId)/Data/Library/Application Support/\(Self.folderName)", isDirectory: true))
            #else
            mirror = mirrorDirectory
            #endif
        }
        self.primaryDirectory = primary
        // A mirror that aliases the primary folder (same path after symlinks, or same device and inode) is dropped.
        self.mirrorDirectory = mirror.flatMap { Self.sameDirectory(primary, $0) ? nil : $0 }
    }

    private static func sameDirectory(_ a: URL, _ b: URL) -> Bool {
        let (ra, rb) = (a.resolvingSymlinksInPath().standardizedFileURL, b.resolvingSymlinksInPath().standardizedFileURL)
        if ra.path == rb.path { return true }
        #if canImport(Darwin) || canImport(Glibc)
        var sa = stat(), sb = stat()
        if stat(ra.path, &sa) == 0, stat(rb.path, &sb) == 0 { return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino }
        #endif
        return false
    }

    // MARK: Preferences and club selection

    /// Lenient read for display surfaces (widget, CLI defaults); writes go through `updatePreferences`.
    public func loadPreferences() -> TertiaPreferences { (try? readPreferences()) ?? TertiaPreferences() }

    /// Defaults only when `preferences.json` does not exist; an unreadable or malformed file throws.
    public func readPreferences() throws -> TertiaPreferences {
        try acquireLock(); defer { lock.unlock() }
        return try readStrict(TertiaPreferences.self, Self.preferencesFile) ?? TertiaPreferences()
    }

    /// Cross-process read-modify-write (`.preferences.lock`), so concurrent app and CLI edits to different fields both
    /// survive and a malformed file is reported instead of being overwritten with defaults. A failed widget-mirror
    /// write is returned as `mirrorError` because the primary file was already committed.
    @discardableResult
    public func updatePreferences(_ mutate: (inout TertiaPreferences) -> Void) throws -> (preferences: TertiaPreferences, mirrorError: Error?) {
        try withFileLock(".preferences.lock") { try updatePreferencesUnlocked(mutate) }
    }

    /// One locked read of the whole account state (`.account.lock` and `.preferences.lock`), also keeping the saved club
    /// available to the account in the Keychain: a signed-in account is realigned to its timetable clubs (home club
    /// first), and a signed-out store whose club is not one of the 17 public clubs returns to Canary Wharf (39). The
    /// session, its Keychain read warning, and its valid cached bookings come from that same read, so an account switch
    /// can never pair one account's name with another account's bookings.
    public func alignPreferencesToCurrentAccount(keychain: KeychainStore) throws -> (preferences: TertiaPreferences, session: MemberSession?, warning: KeychainError?,
                                                                                    bookings: BookingsSnapshot?, catalog: [Club], alignment: ClubAlignment, mirrorError: Error?) {
        try withAccountLock {
            let (session, warning) = try keychain.readSessionWithWarning()
            let bookings = session.flatMap { loadBookingsUnlocked(for: $0) }
            return try flocked(".preferences.lock") {
                let prefs = try readStrict(TertiaPreferences.self, Self.preferencesFile) ?? TertiaPreferences()
                let catalog = session == nil ? signedOutClubCatalogUnlocked() : publicClubCatalogUnlocked()
                let alignment = session.map { prefs.alignment(for: $0, catalog: catalog) } ?? signedOutAlignment(prefs)
                guard case .realigned(let next) = alignment else { return (prefs, session, warning, bookings, catalog, alignment, nil) }
                return (next, session, warning, bookings, catalog, alignment, try writePreferencesUnlocked(next))
            }
        }
    }

    /// Checks the club against the account in the Keychain (all 17 clubs when signed out) and saves it as the widget
    /// club in one step under the account lock, so an account switch cannot slip between check and save. `nil` means
    /// the club is not available to that account; `mirrorError` reports a failed widget-mirror write after the primary
    /// save committed, and `warning` a Keychain UI-restore warning from the read.
    public func selectEntitledClub(clubId: Int, keychain: KeychainStore) throws -> (club: Club, mirrorError: Error?, warning: KeychainError?)? {
        try withAccountLock {
            let (session, warning) = try keychain.readSessionWithWarning()
            let allowed = session.map { $0.entitledClubs(from: publicClubCatalogUnlocked()) } ?? signedOutClubCatalogUnlocked()
            guard let club = allowed.first(where: { $0.id == clubId }) else { return nil }
            let saved = try flocked(".preferences.lock") {
                try updatePreferencesUnlocked { $0.clubId = club.id; $0.clubName = club.name; $0.clubShortCode = club.shortCode }
            }
            return (club, saved.mirrorError, warning)
        }
    }

    // MARK: Public timetables

    /// The stored snapshot for `clubId`; a file holding another club's snapshot returns `nil`.
    public func loadSnapshot(clubId: Int) -> TimetableSnapshot? {
        withBoundedLock(nil) { read(TimetableSnapshot.self, Self.snapshotFile(clubId)).flatMap { $0.clubId == clubId ? $0 : nil } }
    }

    /// Where a class ID resolves across the stored timetables of `clubIds`.
    public enum EntitledClassLookup: Equatable, Sendable {
        case missing
        case unique(session: ClassSession, clubId: Int)
        case ambiguous
        /// A stored timetable of this club exists but is unreadable, malformed, or holds another club.
        case untrusted(clubId: Int)
    }

    /// Stored timetables of a set of clubs, read once (`loadEntitledTimetables`), so a render pass resolves every card
    /// against one state instead of re-reading each club's file per card.
    public struct EntitledTimetableIndex: Sendable {
        /// In club ID order; `nil` marks a stored timetable that is unreadable, malformed, or holds another club.
        fileprivate let clubs: [(id: Int, snapshot: TimetableSnapshot?)]

        /// The one cross-club class search: an ID that is ambiguous inside one club's snapshot, or unique in more than
        /// one club, is `.ambiguous` (the club is never guessed); a club whose stored file cannot be trusted makes the
        /// search `.untrusted` once it is reached.
        public func lookup(_ classId: Int) -> EntitledClassLookup {
            var matches: [(ClassSession, Int)] = []
            for (id, snapshot) in clubs {
                guard let snapshot else { return .untrusted(clubId: id) }
                switch snapshot.lookupSession(id: classId) {
                case .ambiguous: return .ambiguous
                case .unique(let session): matches.append((session, id))
                case .missing: continue
                }
            }
            guard matches.count <= 1 else { return .ambiguous }
            return matches.first.map { .unique(session: $0.0, clubId: $0.1) } ?? .missing
        }

        /// The stored club name of a trusted timetable in this index.
        public func clubName(_ clubId: Int) -> String? { clubs.first { $0.id == clubId }?.snapshot?.clubName }
    }

    /// Reads the stored timetable of each club in `clubIds` once; a club without one is skipped. A lock timeout returns
    /// an index whose every lookup is `.untrusted(clubId: 0)`.
    public func loadEntitledTimetables(clubIds: Set<Int>) -> EntitledTimetableIndex {
        withBoundedLock(EntitledTimetableIndex(clubs: [(0, nil)])) {
            EntitledTimetableIndex(clubs: clubIds.sorted().compactMap { id in
                let path = url(Self.snapshotFile(id)).path
                guard (try? fileManager.attributesOfItem(atPath: path)) != nil || fileManager.fileExists(atPath: path) else { return nil }
                let snap = try? readStrict(TimetableSnapshot.self, Self.snapshotFile(id))
                betweenClubSnapshotReads?(id)
                return (id, snap.flatMap { $0.clubId == id ? $0 : nil })
            })
        }
    }

    /// The cross-club class search shared by the menu, CLI, and MCP (`EntitledTimetableIndex.lookup`). Inside a mutation
    /// handoff `.timetables.lock` is held, so no timetable write interleaves with this search.
    public func lookupEntitledClass(_ classId: Int, clubIds: Set<Int>) -> EntitledClassLookup {
        loadEntitledTimetables(clubIds: clubIds).lookup(classId)
    }

    /// Club names by ID from the signed-in catalog (`publicClubCatalog`), for naming the club of a public row.
    public func clubNamesById() -> [Int: String] {
        Dictionary(publicClubCatalog().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// The public row an undated booking's cancellation falls back to, with its club named from the catalog.
    public func fallbackPublicTarget(_ lookup: EntitledClassLookup, classId: Int) throws -> BookingAuthorization.PublicTarget? {
        try BookingAuthorization.publicTarget(lookup, classId: classId, clubNames: clubNamesById())
    }

    /// Signed-in catalog: the 17 default clubs (with the newest reported name and short code) plus any extra non-hidden
    /// clubs the public site has reported, sorted by name. Before the first `public-clubs.json` exists, clubs from
    /// stored snapshots count, so upgrades keep extra clubs immediately.
    public func publicClubCatalog() -> [Club] { withBoundedLock(Self.byName(Club.defaultClubs)) { publicClubCatalogUnlocked() } }

    /// Signed-out catalog: exactly the 17 default club IDs with the newest reported name and short code, sorted by name.
    public func signedOutClubCatalog() -> [Club] { withBoundedLock(Self.byName(Club.defaultClubs)) { signedOutClubCatalogUnlocked() } }

    /// Next public timetable request number (strictly increasing, never below the current microsecond clock), taken
    /// before the request is sent so overlapping responses merge in request order.
    public func reserveSnapshotSequence() throws -> UInt64 {
        try withFileLock(".sequence.lock") {
            let (incremented, overflow) = (try readStrict(UInt64.self, Self.sequenceFile) ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw StoreError.sequenceExhausted }
            let next = max(incremented, UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000)))
            try writeFile(next, Self.sequenceFile, in: primaryDirectory)
            return next
        }
    }

    /// Merges a fetched range into the on-disk snapshot under `.timetables.lock` and `.snapshot-<club>.lock`. A day is replaced by a later
    /// request (`requestSeq`), or for days stored without a request number by a response at least as new as the stored
    /// stamp. Every stamp written is the request time capped at the completion clock `now` (never in the future after a
    /// clock rollback), and stored stamps more than 2 seconds after `now` are discarded. Dates before yesterday (by the
    /// completion clock) are pruned from disk, but the returned snapshot keeps every fetched day so historical queries
    /// still answer. An unreadable or mismatched existing file throws instead of silently dropping its other days.
    /// Afterwards the widget's booking row tokens are refreshed (`refreshBookingsMirrorIfNeeded`).
    public func mergeAndSaveSnapshot(clubId: Int, clubs: [Club], clubName: String, clubShortCode: String, fetchedDays: [String: [ClassSession]],
                                     fetchedRange: [String], requestSeq: UInt64, syncedAt: Date, now: Date = Date()) throws -> TimetableSnapshot {
        let effectiveSync = Self.persistedDate(min(syncedAt, now))
        // `.timetables.lock` first: a mutation handoff holds it across its cross-club search, so no club's write interleaves.
        let result = try withFileLock(".timetables.lock", ".snapshot-\(clubId).lock") {
            if !clubs.isEmpty { try savePublicClubs(clubs, seq: requestSeq, updatedAt: effectiveSync, now: now) }
            let existing = try readStrict(TimetableSnapshot.self, Self.snapshotFile(clubId))
            if let existing, existing.clubId != clubId { throw CocoaError(.coderInvalidValue) }
            var days = existing?.days ?? [:], stamps = existing?.daySyncedAt ?? [:], revisions = existing?.dayRevision ?? [:]
            Self.dropFutureStamps(&stamps, &revisions, now: now)
            for day in fetchedRange {
                let newer = revisions[day].map { requestSeq >= $0 } ?? stamps[day].map { effectiveSync >= $0 } ?? true
                guard newer else { continue }
                days[day] = fetchedDays[day] ?? []; stamps[day] = effectiveSync; revisions[day] = requestSeq
            }
            let oldest = Self.oldestKeptDay(now: now)
            // Club metadata written by this store (`metaRevision > 0`) is replaced by a later request number; metadata
            // mirrored from the other store (`metaRevision == 0`, a separate counter) only by a request that started no
            // earlier than it was written, so an older pending widget request never undoes a newer host rename. Metadata
            // stamped in the future is always replaced.
            let meta = existing.flatMap { old in old.metaUpdatedAt > now.addingTimeInterval(2)
                || (old.metaRevision > 0 ? requestSeq >= old.metaRevision : effectiveSync >= old.metaUpdatedAt) ? nil
                : (clubs: old.clubs, name: old.clubName, short: old.clubShortCode, rev: old.metaRevision, at: old.metaUpdatedAt) }
                ?? (clubs: clubs.isEmpty ? (existing?.clubs ?? Club.defaultClubs) : clubs, name: clubName, short: clubShortCode, rev: requestSeq, at: effectiveSync)
            func snapshot(keeping keep: (String) -> Bool) -> TimetableSnapshot {
                let keptStamps = stamps.filter { keep($0.key) }
                return TimetableSnapshot(clubs: meta.clubs, clubId: clubId, clubName: meta.name, clubShortCode: meta.short,
                                         days: days.filter { keep($0.key) }, syncedAt: Self.validSyncedAt(keptStamps, fallback: effectiveSync, now: now),
                                         daySyncedAt: keptStamps, dayRevision: revisions.filter { keep($0.key) }, metaRevision: meta.rev, metaUpdatedAt: meta.at)
            }
            let stored = snapshot { $0 >= oldest }
            try writeFile(stored, Self.snapshotFile(clubId), in: primaryDirectory)
            try mergeIntoMirror(stored, now: now)
            return snapshot { $0 >= oldest || fetchedRange.contains($0) }
        }
        refreshBookingsMirrorIfNeeded()
        return result
    }

    /// Merges a valid primary snapshot into a widget mirror copy that is missing, corrupt, for another club, or lacks
    /// (or holds older) primary days, keeping newer valid widget days (called on primary cache hits). An up-to-date
    /// mirror is not rewritten.
    public func repairSnapshotMirrorIfNeeded(clubId: Int) throws {
        guard mirrorDirectory != nil else { return }
        try withFileLock(".snapshot-\(clubId).lock") {
            guard let snap = try readStrict(TimetableSnapshot.self, Self.snapshotFile(clubId)), snap.clubId == clubId else { return }
            try mergeIntoMirror(snap, now: Date())
        }
        refreshBookingsMirrorIfNeeded()
    }

    /// Best effort, after a public timetable write (taken after the timetable locks are released, so the account lock
    /// order is never inverted): rewrites the widget's `bookings.json` when the row tokens of valid cached bookings
    /// changed, which happens only for undated or unnamed bookings that rely on stored timetables (identical bytes are
    /// skipped).
    private func refreshBookingsMirrorIfNeeded() {
        guard mirrorDirectory != nil else { return }
        _ = try? withAccountLock {
            let marker = try readMarkerStrict()
            guard marker.bookingsValid, let snap = read(BookingsSnapshot.self, Self.bookingsFile), snap.revision == marker.revision,
                  marker.ownerId == MemberSession.opaqueId(snap.ownerKey) else { return }
            _ = writeMirror(compactMirror(snap), Self.bookingsFile)
        }
    }

    // MARK: Account and bookings

    /// Cached bookings only when they belong to `session` and `account.json` marks them valid for that owner at the
    /// revision they were committed with (a failed deletion, a lost mutation reply, or a half-written commit never
    /// resurrects a stale file).
    public func loadBookings(for session: MemberSession) -> BookingsSnapshot? { withBoundedLock(nil) { loadBookingsUnlocked(for: session) } }

    /// Active booked IDs, shown only when this directory's `account.json` marks the bookings valid for its owner and
    /// `bookings.json` belongs to that owner (and to `expectedOwnerId` when given). Inside the widget this reads the
    /// container mirror.
    public func loadBookedIds(expectedOwnerId: String? = nil) -> Set<Int> {
        withBoundedLock([]) { Set(loadBookedMirrorUnlocked(expectedOwnerId: expectedOwnerId)?.bookedIds ?? []) }
    }

    /// What the widget renders: preferences, the selected club's snapshot, the IDs it may badge, and the mirror's row
    /// tokens (`nil` for a legacy mirror without them).
    public typealias WidgetStateRead = (preferences: TertiaPreferences, snapshot: TimetableSnapshot?, bookedIds: Set<Int>, rowTokens: Set<String>?)

    /// Preferences, the snapshot of the preferred club, and the booked IDs read as one consistent state under
    /// `.account.lock` and `.preferences.lock`, read twice. When preferences or the booked mirror changed between the two
    /// reads (a writer that does not take these locks), no booked IDs are returned, so a badge never pairs with a
    /// half-written account change. Stored timetables are decoded once: an ID is badged only when it resolves to one row
    /// of the shown club, appears in no other club's snapshot (`unambiguousWidgetBookedIds`), and, with row tokens, that
    /// row is London today at `now` and its token names the shown club; any unreadable stored timetable (or folder)
    /// drops them all. With no stored snapshot of the shown club, the raw IDs are returned (no rows exist to badge). A
    /// lock timeout returns defaults at once (no further lock waits).
    public func readConsistentWidgetState(now: Date = Date()) -> WidgetStateRead {
        let state: Result<WidgetStateRead, Error> = Result { try withAccountLock {
            try flocked(".preferences.lock") { () -> WidgetStateRead in
                func mirrorAndPrefs() -> (BookedIdsMirror?, TertiaPreferences) {
                    (loadBookedMirrorUnlocked(expectedOwnerId: nil), read(TertiaPreferences.self, Self.preferencesFile) ?? TertiaPreferences())
                }
                let (first, firstPrefs) = mirrorAndPrefs()
                betweenWidgetReads?()
                let (mirror, prefs) = mirrorAndPrefs()
                guard first == mirror, firstPrefs == prefs, let mirror, !mirror.bookedIds.isEmpty else { return (prefs, loadSnapshot(clubId: prefs.clubId), [], []) }
                let peers = storedSnapshotsUnlocked()
                let snapshot = peers.snapshots.first { $0.clubId == prefs.clubId }
                let ids = Set(mirror.bookedIds), tokens = mirror.rowTokens.map(Set.init)
                guard !peers.corrupt else { return (prefs, snapshot, [], []) }
                guard let snapshot else { return (prefs, nil, ids, tokens) }
                let today = LondonCalendar.londonTodayIso(now: now)
                let badged = Self.unambiguousWidgetBookedIds(ids, selectedClubId: prefs.clubId, selectedSnapshot: snapshot, otherSnapshots: peers.snapshots).filter { id in
                    guard case .unique(let row) = snapshot.lookupSession(id: id) else { return false }
                    return tokens.map { tokens in
                        row.date == today && [prefs.clubName, row.clubName].contains { tokens.contains(Self.widgetRowToken(classId: id, clubName: $0, dateIso: row.date)) }
                    } ?? true
                }
                return (prefs, snapshot, badged, tokens)
            }
        } }
        switch state {
        case .success(let state): return state
        case .failure(StoreError.lockTimedOut): return (TertiaPreferences(), nil, [], [])
        case .failure:
            let prefs = loadPreferences()
            return (prefs, loadSnapshot(clubId: prefs.clubId), [], [])
        }
    }

    /// The booked IDs a widget may badge for the selected club: none when any stored timetable is unreadable; otherwise
    /// only IDs that resolve uniquely in `selectedSnapshot` (when they appear there at all) and appear in no other
    /// club's snapshot, so a class ID shared by two clubs never shows `BOOKED` on the wrong club's row.
    public static func unambiguousWidgetBookedIds(_ bookedIds: Set<Int>, selectedClubId: Int, selectedSnapshot: TimetableSnapshot?,
                                                  otherSnapshots: [TimetableSnapshot], hasCorruptPeerSnapshot: Bool = false) -> Set<Int> {
        guard !bookedIds.isEmpty, !hasCorruptPeerSnapshot else { return [] }
        let peers = otherSnapshots.filter { $0.clubId != selectedClubId }
        return bookedIds.filter { id in
            if let selectedSnapshot, selectedSnapshot.days.values.joined().contains(where: { $0.id == id }) {
                guard case .unique = selectedSnapshot.lookupSession(id: id) else { return false }
            }
            return !peers.contains { $0.days.values.joined().contains { $0.id == id } }
        }
    }

    /// Every `snapshot-<club>.json` in this store's folder, strictly decoded; `corrupt` when the folder exists but cannot
    /// be listed, or when any snapshot is unreadable, malformed, or holds another club.
    private func storedSnapshotsUnlocked() -> (snapshots: [TimetableSnapshot], corrupt: Bool) {
        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: primaryDirectory.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return ([], false) }
        catch { return ([], true) }
        var snapshots: [TimetableSnapshot] = [], corrupt = false
        for name in names.sorted() where name.hasPrefix("snapshot-") && name.hasSuffix(".json") {
            guard let id = Int(name.dropFirst("snapshot-".count).dropLast(".json".count)) else { continue }
            if let snap = try? readStrict(TimetableSnapshot.self, name), snap.clubId == id { snapshots.append(snap) } else { corrupt = true }
        }
        return (snapshots, corrupt)
    }

    /// Brings `account.json`, the widget mirror, and the mirror `preferences.json` in line with the Keychain and the
    /// primary files on launch and reload, with zero network calls: only missing, legacy, corrupt, or mismatched files are
    /// rewritten (an aligned store gets zero writes), and a signed-out store loses its account files. Account files are
    /// left alone when the Keychain no longer holds `session`. A private mirror file that is injected or already exists
    /// and cannot be repaired or removed throws; a failed preferences mirror repair is returned.
    @discardableResult
    public func reconcileAccountMirror(for session: MemberSession?, keychain: KeychainStore) throws -> Error? {
        try withAccountLock {
            let live = try keychain.readSession()
            if session.map({ Self.matchesSession(live, $0) }) ?? (live == nil) { try reconcileAccountFilesUnlocked(for: session) }
            betweenAccountAndPreferences?()
            guard let mirrorDirectory else { return nil }
            return try flocked(".preferences.lock") { () -> Error? in
                // A missing primary file means the host uses defaults, so the widget copy is reset to them too.
                let prefs = try readStrict(TertiaPreferences.self, Self.preferencesFile) ?? TertiaPreferences()
                do { try writeFile(prefs, Self.preferencesFile, in: mirrorDirectory); return nil } catch { return error }
            }
        }
    }

    /// Run before a sign-in request is sent: the account revision and Keychain credential the login starts from (see
    /// `commitLogin`), plus a Keychain read warning. A corrupt `account.json` throws; an unreadable Keychain item counts
    /// as a credential of its own, so a sign-in can still replace it.
    public func beginLogin(keychain: KeychainStore) throws -> (attempt: LoginAttempt, warning: KeychainError?) {
        try withAccountLock {
            let marker = try readMarkerStrict()
            let (digest, warning) = Self.credentialDigest(keychain)
            return (LoginAttempt(revision: marker.revision, startingTokenDigest: digest), warning)
        }
    }

    /// Saves the new Keychain session first (a failure leaves the previous account fully intact), then marks the new
    /// account. Throws `.sessionSuperseded`, touching nothing, when the account revision or the Keychain credential
    /// changed since `beginLogin` returned `attempt` (sign-out, another sign-in, sync, or mutation; a sign-out that
    /// deleted the credential but failed to save its marker still counts). The cached bookings are invalidated and both
    /// `bookings.json` copies removed whoever signs in (the login's own sync replaces them), each step attempted
    /// independently, so a failed widget marker write never keeps the previous badges. Returns the first cache cleanup
    /// error and a Keychain warning without undoing the login. When an unreadable item was already deleted
    /// (`.previousSessionLost`), local account files are cleared and the club realigned to match the signed-out Keychain, and a cleanup failure is
    /// reported inside the rethrown error. A corrupt `account.json` throws before the Keychain is touched and is never
    /// overwritten (its revision would otherwise restart at 0).
    public func commitLogin(_ session: MemberSession, attempt: LoginAttempt, keychain: KeychainStore) throws -> (cacheError: Error?, warning: KeychainError?) {
        guard session.ownerKey != nil else { throw BookingClientError.invalidResponse }
        return try withAccountLock {
            var marker = try readMarkerStrict()
            let (liveDigest, readWarning) = Self.credentialDigest(keychain)
            guard marker.revision == attempt.revision, liveDigest == attempt.startingTokenDigest else { throw BookingClientError.sessionSuperseded }
            // Checked before the Keychain is touched, so an exhausted revision leaves the previous credential and files intact.
            guard marker.revision < .max else { throw StoreError.revisionExhausted }
            let warning: KeychainError?
            do { warning = try keychain.saveSession(session) ?? readWarning } catch KeychainError.previousSessionLost(let code, _) {
                do { try attemptAll([{ try self.clearAccountFiles() }, { try self.realignSignedOutClubUnlocked() }]) }
            catch { throw KeychainError.previousSessionLost(code, cleanupError: error.localizedDescription) }
                throw KeychainError.previousSessionLost(code)
            }
            try marker.advance(); marker.bind(to: session); marker.bookingsValid = false
            do {
                try attemptAll([{ try self.writeAccount(marker) }, { try self.remove(Self.bookingsFile) }])
                return (nil, warning)
            } catch { return (error, warning) }
        }
    }

    /// `MemberSession.opaqueId` of the Keychain token (`nil` when none is stored) with the read warning; an unreadable
    /// item maps to a stable marker naming its error.
    private static func credentialDigest(_ keychain: KeychainStore) -> (digest: String?, warning: KeychainError?) {
        do {
            let (session, warning) = try keychain.readSessionWithWarning()
            return (session.map { MemberSession.opaqueId($0.token) }, warning)
        } catch { return ("unreadable:\(error)", nil) }
    }

    /// Transport handoff gate: holds `.account.lock` while it checks that the Keychain still holds `session` (else
    /// `.sessionSuperseded`) and runs `handoff` with that live session (launching the request and passing it its
    /// credentials), so a sign-out or account switch can never interleave with a credential leaving the process.
    /// Waiting for the reply happens after.
    public func withAuthorizedTransportHandoff<T>(for session: MemberSession, keychain: KeychainStore, _ handoff: (MemberSession) throws -> T) throws -> T {
        try withAccountLock {
            guard let live = try keychain.readSession(), Self.matchesSession(live, session) else { throw BookingClientError.sessionSuperseded }
            return try handoff(live)
        }
    }

    /// Run before a bookings fetch: throws `.sessionSuperseded` (before any request is sent) unless the Keychain holds
    /// `session`, and `.staleRefresh` while another book or cancel holds `.mutation.lock` (unless this sync is that
    /// mutation's own follow-up, `completingMutation`). Issues the next sync request number (persisted without changing
    /// the revision) and returns it with the account revision the fetch starts from. A corrupt `account.json` throws, and
    /// an exhausted revision throws before anything is written (zero requests).
    public func beginBookingsSync(for session: MemberSession, keychain: KeychainStore, completingMutation: Bool = false) throws -> (startedAtRevision: UInt64, syncSeq: UInt64) {
        try withAccountLock {
            guard Self.matchesSession(try keychain.readSession(), session) else { throw BookingClientError.sessionSuperseded }
            if !completingMutation { try verifyNoMutationInFlightUnlocked() }
            var marker = try readMarkerStrict()
            guard marker.revision < .max else { throw StoreError.revisionExhausted }
            let (seq, overflow) = marker.lastIssuedSyncSeq.addingReportingOverflow(1)
            guard !overflow else { throw StoreError.revisionExhausted }
            marker.lastIssuedSyncSeq = seq
            try writeFile(marker, Self.accountFile, in: primaryDirectory)
            return (marker.revision, marker.lastIssuedSyncSeq)
        }
    }

    /// Commits fetched bookings only while the Keychain still holds `session` (else `.sessionSuperseded`). A refresh
    /// started before the last mutation acceptance, sign-in, or invalidation (`startedAtRevision <
    /// minValidSyncRevision`), or one finishing while another mutation holds `.mutation.lock` (unless
    /// `completingMutation`), throws `.staleRefresh` and never commits, as does a `syncSeq` or `startedAtRevision` that
    /// `beginBookingsSync` never issued. Overlapping refreshes commit in request order (`syncSeq`): a refresh started no
    /// later than the last committed one (including a replay of it) returns that stored snapshot unchanged, and a later
    /// one replaces an earlier one's commit. `bookings.json` (stamped with the new revision) commits before the
    /// `account.json` that validates it; a failed widget mirror write is returned as `mirrorError`, never thrown.
    public func commitSyncedBookings(_ bookings: [MemberBooking], for session: MemberSession, startedAtRevision: UInt64, syncSeq: UInt64, syncedAt: Date = Date(),
                                     keychain: KeychainStore, completingMutation: Bool = false) throws -> (snapshot: BookingsSnapshot, mirrorError: Error?) {
        guard let ownerKey = session.ownerKey else { throw BookingClientError.invalidResponse }
        return try withAccountLock {
            guard Self.matchesSession(try keychain.readSession(), session) else { throw BookingClientError.sessionSuperseded }
            if !completingMutation { try verifyNoMutationInFlightUnlocked() }
            var marker = try readMarkerStrict()
            guard syncSeq > 0, syncSeq <= marker.lastIssuedSyncSeq, startedAtRevision <= marker.revision, startedAtRevision >= marker.minValidSyncRevision else {
                throw BookingClientError.staleRefresh
            }
            if marker.bookingsValid && syncSeq <= marker.lastCommittedSyncSeq {
                guard let existing = loadBookingsUnlocked(for: session, marker: marker) else { throw BookingClientError.staleRefresh }
                return (existing, nil)
            }
            let (revision, overflow) = marker.revision.addingReportingOverflow(1)
            guard !overflow else { throw StoreError.revisionExhausted }
            marker.bind(to: session); marker.bookingsValid = true; marker.revision = revision; marker.lastCommittedSyncSeq = syncSeq
            let snap = BookingsSnapshot(ownerKey: ownerKey, bookings: bookings, syncedAt: syncedAt, revision: marker.revision,
                                        sessionTokenDigest: MemberSession.opaqueId(session.token))
            // Bookings first, then the marker that validates them; a crash in between leaves a revision mismatch (never valid).
            try writeFile(snap, Self.bookingsFile, in: primaryDirectory)
            try writeFile(marker, Self.accountFile, in: primaryDirectory)
            // Same order in the mirror; a failed bookings copy removes the mirror marker (an older one could still validate
            // the previous same-owner IDs), so the widget shows no badges until a repair succeeds.
            let mirrorError: Error?
            if let error = writeMirror(compactMirror(snap), Self.bookingsFile) {
                if let mirrorDirectory { try? removeFile(Self.accountFile, in: mirrorDirectory) }
                mirrorError = error
            } else { mirrorError = writeMirror(marker.mirror, Self.accountFile) }
            return (read(BookingsSnapshot.self, Self.bookingsFile) ?? snap, mirrorError) // as stored (millisecond dates)
        }
    }

    /// Gate step of a class mutation, run after `.mutation.lock` is held: under `.account.lock`, verifies the Keychain
    /// still holds `session` (else `.sessionSuperseded`) and runs `authorize` on the live session, its valid cached
    /// bookings, and this store (read-only APIs such as `publicClubCatalog` and `loadSnapshot` are safe). A refusal
    /// changes nothing, so valid bookings stay usable for an immediate retry. When `dispatching`, and only after
    /// `authorize` succeeded, the cache is marked invalid and the revision advanced (persisted) before `handoff` launches
    /// the request, still under the lock, so a lost reply or crash requires a Refresh first. `onWillDispatch` runs at
    /// that point (before the invalidation is persisted), so the caller knows a request may have left. `.timetables.lock`
    /// is held from `authorize` through `handoff` (released before the reply is awaited), so no timetable write on any
    /// club interleaves with the cross-club search behind the authorization.
    public func withAuthorizedMutationHandoff<T>(for session: MemberSession, keychain: KeychainStore, dispatching: Bool, onWillDispatch: () -> Void = {},
                                                 authorize: (MemberSession, BookingsSnapshot?, SharedStateStore) throws -> T, _ handoff: (T) throws -> Void) throws {
        try withAccountLock(thenLocking: ".timetables.lock") {
            guard let live = try keychain.readSession(), Self.matchesSession(live, session) else { throw BookingClientError.sessionSuperseded }
            var marker = try readMarkerStrict()
            let result = try authorize(live, loadBookingsUnlocked(for: live, marker: marker), self)
            if dispatching {
                try marker.advance()
                onWillDispatch()
                marker.bookingsValid = false; marker.bind(to: live)
                try writeAccount(marker)
            }
            try handoff(result)
        }
    }

    /// Run when the server accepted a book or cancel, before the follow-up sync: advances the revision so any refresh
    /// that started before the acceptance is rejected. Throws `.sessionSuperseded` (leaving `account.json` untouched)
    /// unless the Keychain still holds `session` with its owner and `account.json` still names that owner.
    public func markMutationAccepted(for session: MemberSession, keychain: KeychainStore) throws {
        try withAccountLock {
            let live = try keychain.readSession()
            var marker = try readMarkerStrict()
            guard Self.matchesSession(live, session), marker.ownerId == session.opaqueOwnerId else {
                throw BookingClientError.sessionSuperseded
            }
            try marker.advance()
            try writeAccount(marker)
        }
    }

    /// Run when a book or cancel request failed after passing its gate (the server may still have applied it): while the
    /// Keychain still holds `session`, marks the cache invalid and advances the revision so only a Refresh that starts
    /// after this point (and after `.mutation.lock` is released) can make bookings valid again. Best effort: the
    /// dispatch error is what the caller reports.
    public func ensureBookingsInvalidatedAfterFailedDispatch(for session: MemberSession, keychain: KeychainStore) {
        _ = try? withAccountLock {
            guard Self.matchesSession(try keychain.readSession(), session) else { return }
            var marker = try readMarkerStrict()
            marker.invalidate()
            try writeAccount(marker)
        }
    }

    /// Serializes book and cancel requests across processes with one `.mutation.lock` for the whole mutation plus
    /// follow-up sync. Waiting polls a non-blocking lock (cancellable, at most `mutationLockTimeout` on the monotonic
    /// clock), so no thread blocks and the in-process store lock is never held across `await`. Non-positive IDs throw
    /// before any lock file.
    public func withMutationLock<T>(classId: Int, _ body: () async throws -> T) async throws -> T {
        guard classId > 0 else { throw StoreError.invalidClassId(classId) }
        #if canImport(Darwin) || canImport(Glibc)
        let fd = try openLockFile(".mutation.lock", in: primaryDirectory)
        defer { close(fd) }
        let deadline = uptime() + mutationLockTimeout
        // The first attempt is unconditional; after contention the deadline is checked before and after every sleep, so
        // a lock released after the deadline is never taken.
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { throw CocoaError(.fileLocking) }
            try Task.checkCancellation()
            guard uptime() < deadline else { throw StoreError.lockTimedOut(".mutation.lock") }
            try await Task.sleep(nanoseconds: 5_000_000)
            guard uptime() < deadline else { throw StoreError.lockTimedOut(".mutation.lock") }
        }
        defer { flock(fd, LOCK_UN) }
        #endif
        return try await body()
    }

    /// Invalidates the cache after a failed follow-up sync (no other refresh can commit while `.mutation.lock` is
    /// held). Leaves everything untouched when another sign-in or a sign-out replaced `session` (`.superseded`).
    public func invalidateBookingsForFailedFollowUp(for session: MemberSession, keychain: KeychainStore) -> FollowUpCleanupOutcome {
        do {
            return try withAccountLock {
                guard Self.matchesSession(try keychain.readSession(), session) else { return .superseded }
                var marker = try readMarkerStrict()
                marker.invalidate()
                try attemptAll([{ try self.writeAccount(marker) }, { try self.remove(Self.bookingsFile) }])
                return .cleared
            }
        } catch { return .failed(error.localizedDescription) }
    }

    /// Sign-out: deletes the Keychain session (throws if that fails, as `SignOutError` when a Keychain read warning
    /// preceded it, leaving every file untouched), then clears local account files, returns a selected member-only club
    /// to Canary Wharf (a club outside the 17 signed-out clubs is never kept), and aligns the widget's `preferences.json`
    /// with the primary one, all before the caller notifies other surfaces. Only the primary `.account.lock` is
    /// required: a widget mirror whose `.account.lock` cannot be taken is left unwritten and reported as `cacheError`, so
    /// a busy or broken widget container never blocks a local sign-out. Cleanup errors and a Keychain warning are
    /// returned separately because the credential is already gone. With `expectedSession`, nothing is touched
    /// (`didClear == false`) unless the Keychain still holds that session (token and owner); a warning from that read is
    /// returned either way. Without it, a best-effort read (whose failure never blocks the delete) still supplies any
    /// Keychain warning.
    @discardableResult
    public func clearSession(expectedSession: MemberSession? = nil, keychain: KeychainStore) throws -> (didClear: Bool, cacheError: Error?, warning: KeychainError?) {
        var readWarning: KeychainError?
        return try clearSession(expectedSession: expectedSession, keychain: keychain, readWarning: &readWarning)
    }

    /// Expires a rejected session only while the Keychain holds it (token and owner); a replacement session is never
    /// touched. A Keychain warning is carried in every outcome, including a failed delete after a successful read. When
    /// that delete fails, each cached-bookings invalidation step still runs independently before `.failed` is returned:
    /// `invalidatedCache` (`didMutateDisk`) when any step changed disk, and `cacheError` naming the first that failed.
    public func expireSession(for session: MemberSession, keychain: KeychainStore) -> SessionExpiryOutcome {
        var readWarning: KeychainError?, invalidated = false, cleanupError: Error?
        do {
            let result = try clearSession(expectedSession: session, keychain: keychain, readWarning: &readWarning) { mirrorError in
                (invalidated, cleanupError) = self.invalidateCacheAfterFailedDelete(mirrorError: mirrorError)
            }
            return result.didClear ? .cleared(cacheError: result.cacheError, warning: result.warning) : .superseded(warning: result.warning)
        } catch {
            return .failed((error as? SignOutError)?.underlying ?? error, cacheError: cleanupError, warning: readWarning, invalidatedCache: invalidated)
        }
    }

    /// `clearSession` that reports the `expectedSession` read warning through `readWarning` as soon as it is known, and
    /// runs `onDeleteFailure` (with the mirror lock error, if any) under the locks before a failed delete is rethrown.
    private func clearSession(expectedSession: MemberSession?, keychain: KeychainStore, readWarning: inout KeychainError?,
                              onDeleteFailure: ((Error?) -> Void)? = nil) throws -> (didClear: Bool, cacheError: Error?, warning: KeychainError?) {
        let deadline = uptime() + lockTimeout
        try acquireLock(".account.lock", deadline: deadline)
        defer { lock.unlock() }
        let primaryFd = try lockFile(".account.lock", in: primaryDirectory, deadline: deadline)
        defer { unlockFile(primaryFd) }
        // The mirror lock is optional here: on failure the mirror is never written unlocked, and the error is reported.
        var mirrorError: Error?, mirrorFd: Int32?
        do { mirrorFd = try lockMirrorAccount(deadline: deadline) } catch { mirrorError = error }
        defer { if let mirrorFd { unlockFile(mirrorFd) } }
        let mirror = mirrorError == nil
        if let expectedSession {
            let (current, warning) = try keychain.readSessionWithWarning()
            readWarning = warning
            guard Self.matchesSession(current, expectedSession) else { return (false, nil, warning) }
        } else {
            // Best effort, never blocking the delete: an unconditional sign-out (CLI `logout`) reads first too, so a
            // Keychain warning of that read is reported with a failed delete (`SignOutError`) or a completed sign-out.
            readWarning = (try? keychain.readSessionWithWarning())?.warning
        }
        let deleteWarning: KeychainError?
        do { deleteWarning = try keychain.deleteSession() } catch {
            onDeleteFailure?(mirrorError)
            throw readWarning == nil ? error : SignOutError(underlying: error, warning: readWarning)
        }
        do { try attemptAll([{ try self.clearAccountFiles(mirror: mirror) }, { try self.realignSignedOutClubUnlocked(mirror: mirror) }]) }
        catch { return (true, error, deleteWarning ?? readWarning) }
        return (true, mirrorError, deleteWarning ?? readWarning)
    }

    /// Expiry with a failed Keychain delete: invalidates the primary marker and removes both `bookings.json` copies and
    /// the widget marker, each step independently (mirror steps only while its lock is held; otherwise `mirrorError` is
    /// the cleanup failure). Returns whether any step changed disk and the first failure.
    private func invalidateCacheAfterFailedDelete(mirrorError: Error?) -> (mutated: Bool, error: Error?) {
        var steps: [() throws -> Void] = [{
            var marker = try self.readMarkerStrict()
            marker.invalidate()
            try self.writeFile(marker, Self.accountFile, in: self.primaryDirectory)
        }, { try self.removeFile(Self.bookingsFile, in: self.primaryDirectory) }]
        if mirrorError == nil, let mirrorDirectory {
            steps += [Self.accountFile, Self.bookingsFile].map { name in { try self.removeFile(name, in: mirrorDirectory) } }
        }
        let outcome = runAll(steps)
        return (outcome.anySucceeded, outcome.firstError ?? mirrorError)
    }

    /// Whether the Keychain's `live` session is `expected`: same non-empty token and same owner. Every session-bound
    /// gate uses it, so another owner holding the same token never passes.
    private static func matchesSession(_ live: MemberSession?, _ expected: MemberSession) -> Bool {
        guard let live, let key = expected.ownerKey, !expected.token.isEmpty else { return false }
        return live.token == expected.token && live.ownerKey == key
    }

    // MARK: Plumbing (callers hold `lock`)

    private static func snapshotFile(_ clubId: Int) -> String { "snapshot-\(clubId).json" }
    private static func oldestKeptDay(now: Date) -> String { LondonCalendar.addDays(to: LondonCalendar.londonTodayIso(now: now), days: -1) ?? "" }

    private static func dropFutureStamps(_ stamps: inout [String: Date], _ revisions: inout [String: UInt64], now: Date) {
        for (day, stamp) in stamps where stamp > now.addingTimeInterval(2) { stamps[day] = nil; revisions[day] = nil }
    }

    /// `.account.lock` in the primary directory and then in the widget mirror (one monotonic deadline), so the widget's
    /// `readConsistentWidgetState`, which locks its own container's `.account.lock`, never reads between the host's
    /// account and preferences writes. A default mirror that cannot be created or locked and does not exist (no widget
    /// container yet) is skipped; an injected or existing mirror must be locked.
    /// `extra` names primary lock files taken after the account locks with the same deadline (`.timetables.lock`).
    private func withAccountLock<T>(thenLocking extra: String? = nil, _ body: () throws -> T) throws -> T {
        let deadline = uptime() + lockTimeout
        try acquireLock(".account.lock", deadline: deadline)
        defer { lock.unlock() }
        let primaryFd = try lockFile(".account.lock", in: primaryDirectory, deadline: deadline)
        defer { unlockFile(primaryFd) }
        let mirrorFd = try lockMirrorAccount(deadline: deadline)
        defer { if let mirrorFd { unlockFile(mirrorFd) } }
        guard let extra else { return try body() }
        return try flocked(extra, deadline: deadline, body)
    }

    /// Locks the widget mirror's `.account.lock`; `nil` when there is no mirror, or when a default mirror that does not
    /// exist (no widget container yet) cannot be locked. An injected or existing mirror that cannot be locked throws.
    private func lockMirrorAccount(deadline: TimeInterval) throws -> Int32? {
        guard let mirrorDirectory else { return nil }
        do { return try lockFile(".account.lock", in: mirrorDirectory, deadline: deadline) }
        catch where !mirrorIsExplicit && !fileManager.fileExists(atPath: mirrorDirectory.path) { return nil }
    }

    /// Revision `0` only when `account.json` does not exist; a corrupt or unreadable file throws.
    private func readMarkerStrict() throws -> AccountMarker { try readStrict(AccountMarker.self, Self.accountFile) ?? AccountMarker() }

    private func loadBookingsUnlocked(for session: MemberSession) -> BookingsSnapshot? {
        guard let marker = try? readMarkerStrict() else { return nil }
        return loadBookingsUnlocked(for: session, marker: marker)
    }

    /// Valid only when the snapshot carries the marker's revision and was fetched with `session`'s own token (legacy
    /// files: revision `0` and no digest), so a `bookings.json` whose validating `account.json` write never landed, or one
    /// left by a replaced credential of the same member, is rejected.
    private func loadBookingsUnlocked(for session: MemberSession, marker: AccountMarker) -> BookingsSnapshot? {
        guard marker.bookingsValid, let ownerId = session.opaqueOwnerId, marker.ownerId == ownerId, let ownerKey = session.ownerKey,
              let snap = read(BookingsSnapshot.self, Self.bookingsFile), snap.ownerKey == ownerKey, snap.revision == marker.revision,
              snap.sessionTokenDigest == MemberSession.opaqueId(session.token) || (snap.sessionTokenDigest.isEmpty && marker.revision == 0) else { return nil }
        return snap
    }

    private func loadBookedMirrorUnlocked(expectedOwnerId: String?) -> BookedIdsMirror? {
        guard let account = read(MirrorAccountMarker.self, Self.accountFile), account.bookingsValid, let owner = account.ownerId, !owner.isEmpty,
              expectedOwnerId == nil || expectedOwnerId == owner else { return nil }
        // A full primary snapshot counts only at the marker's revision (an uncommitted `bookings.json` never shows).
        let compact = read(BookedIdsMirror.self, Self.bookingsFile)
            ?? read(BookingsSnapshot.self, Self.bookingsFile).flatMap { $0.revision == (account.revision ?? 0) ? compactMirror($0) : nil }
        return compact?.ownerId == owner ? compact : nil
    }

    /// The account-file half of `reconcileAccountMirror`; the caller holds `.account.lock` and checked the Keychain.
    private func reconcileAccountFilesUnlocked(for session: MemberSession?) throws {
        guard let session else {
            let marker = try? readMarkerStrict()
            let leftovers = [url(Self.bookingsFile)] + [mirrorDirectory].compactMap { $0 }.flatMap { [url(Self.accountFile, in: $0), url(Self.bookingsFile, in: $0)] }
            if marker?.ownerId != nil || leftovers.contains(where: { fileManager.fileExists(atPath: $0.path) }) { try clearAccountFiles() }
            return
        }
        var marker = try readMarkerStrict()
        let sameOwner = marker.ownerId == session.opaqueOwnerId
        marker.bind(to: session)
        marker.bookingsValid = marker.bookingsValid && sameOwner
        let snap = marker.bookingsValid ? loadBookingsUnlocked(for: session, marker: marker) : nil
        if snap == nil { marker.bookingsValid = false }
        try writeFile(marker, Self.accountFile, in: primaryDirectory)
        guard let mirrorDirectory else { return }
        // The widget's `account.json` validates only booked IDs already written: bookings first when valid (a failed copy
        // removes the mirror marker), and the unvalidated marker before the bookings removal otherwise.
        if let snap, let error = writeMirror(compactMirror(snap), Self.bookingsFile) {
            try? removeFile(Self.accountFile, in: mirrorDirectory)
            throw error
        }
        if let error = writeMirror(marker.mirror, Self.accountFile) { throw error }
        if snap == nil { try removeFile(Self.bookingsFile, in: mirrorDirectory) }
    }

    /// Proves no other book or cancel holds `.mutation.lock` right now (a non-blocking probe that releases at once):
    /// throws `.staleRefresh` while one does, and a file error when the lock cannot be opened or probed (never idle).
    private func verifyNoMutationInFlightUnlocked() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = try openLockFile(".mutation.lock", in: primaryDirectory, permissionCode: .fileReadNoPermission)
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return }
        if errno == EWOULDBLOCK || errno == EAGAIN { throw BookingClientError.staleRefresh }
        throw CocoaError(.fileLocking)
        #endif
    }

    /// A signed-out store keeps a club among the 17 public clubs, else returns to Canary Wharf (39) with its newest
    /// reported name and short code.
    private func signedOutAlignment(_ prefs: TertiaPreferences) -> ClubAlignment {
        guard !Club.defaultClubs.contains(where: { $0.id == prefs.clubId }) else { return .unchanged }
        let home = signedOutClubCatalogUnlocked().first { $0.id == 39 } ?? Club(id: 39, name: "Canary Wharf", shortCode: "CANARY")
        var next = prefs
        next.clubId = home.id; next.clubName = home.name; next.clubShortCode = home.shortCode
        return .realigned(next)
    }

    /// Sign-out step: applies `signedOutAlignment` to `preferences.json` and writes the result to the primary and
    /// mirror copies under `.preferences.lock` (identical bytes are skipped), so the widget never keeps a stale club.
    private func realignSignedOutClubUnlocked(mirror: Bool = true) throws {
        try flocked(".preferences.lock") {
            let prefs = try readStrict(TertiaPreferences.self, Self.preferencesFile) ?? TertiaPreferences()
            let final = if case .realigned(let next) = signedOutAlignment(prefs) { next } else { prefs }
            if let mirrorError = try writePreferencesUnlocked(final, mirror: mirror) { throw mirrorError }
        }
    }

    private func updatePreferencesUnlocked(_ mutate: (inout TertiaPreferences) -> Void) throws -> (preferences: TertiaPreferences, mirrorError: Error?) {
        var prefs = try readStrict(TertiaPreferences.self, Self.preferencesFile) ?? TertiaPreferences()
        mutate(&prefs)
        return (prefs, try writePreferencesUnlocked(prefs))
    }

    /// Commits `preferences.json` first; a widget-mirror failure is returned instead of thrown (`mirror: false` skips it).
    private func writePreferencesUnlocked(_ prefs: TertiaPreferences, mirror: Bool = true) throws -> Error? {
        try writeFile(prefs, Self.preferencesFile, in: primaryDirectory)
        guard mirror, let mirrorDirectory else { return nil }
        do { try writeFile(prefs, Self.preferencesFile, in: mirrorDirectory); return nil } catch { return error }
    }

    /// Clubs the public site reported (or, before the first `public-clubs.json`, clubs from stored snapshots).
    private func reportedClubs() -> [Club] {
        readPublicClubs()?.clubs ?? ((try? fileManager.contentsOfDirectory(atPath: primaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix("snapshot-") && $0.hasSuffix(".json") }.sorted()
            .flatMap { read(ClubsOnly.self, $0)?.clubs ?? [] }
    }

    private static func byName(_ clubs: [Club]) -> [Club] { clubs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    /// The 17 default clubs with reported names and short codes overlaid, plus extra reported clubs when `includeExtra`.
    private func clubCatalogUnlocked(includeExtra: Bool) -> [Club] {
        let reported = reportedClubs()
        var byId: [Int: Club] = [:]
        for club in reported where byId[club.id] == nil { byId[club.id] = club }
        let base = Club.defaultClubs.map { club in
            byId[club.id].map { Club(id: club.id, name: $0.name.isEmpty ? club.name : $0.name, shortCode: $0.shortCode.isEmpty ? club.shortCode : $0.shortCode) } ?? club
        }
        guard includeExtra else { return Self.byName(base) }
        var seen = Set(base.map(\.id))
        return Self.byName(base + reported.filter { seen.insert($0.id).inserted })
    }

    private func publicClubCatalogUnlocked() -> [Club] { clubCatalogUnlocked(includeExtra: true) }
    private func signedOutClubCatalogUnlocked() -> [Club] { clubCatalogUnlocked(includeExtra: false) }

    /// The newest valid (not future) day stamp, else `fallback` capped at `now`.
    private static func validSyncedAt(_ stamps: [String: Date], fallback: Date, now: Date) -> Date {
        stamps.values.filter { $0 <= now.addingTimeInterval(2) }.max() ?? min(fallback, now)
    }

    /// The stored club list; legacy files hold a bare array (request number 0, so any new response replaces them).
    private func readPublicClubs() -> PublicClubsRecord? {
        read(PublicClubsRecord.self, Self.publicClubsFile) ?? read([Club].self, Self.publicClubsFile).map { PublicClubsRecord(updatedAt: .distantPast, seq: 0, clubs: $0) }
    }

    /// Replaces `public-clubs.json` only with a later request (or over a record stamped in the future by a clock rollback).
    private func savePublicClubs(_ clubs: [Club], seq: UInt64, updatedAt: Date, now: Date) throws {
        try flocked(".public-clubs.lock") {
            if let stored = readPublicClubs(), stored.updatedAt <= now.addingTimeInterval(2), stored.seq > seq { return }
            try writeFile(PublicClubsRecord(updatedAt: updatedAt, seq: seq, clubs: clubs), Self.publicClubsFile, in: primaryDirectory)
        }
    }

    /// Merges `snap` into the widget mirror's copy under the mirror's own `.snapshot-<club>.lock`, keeping whichever
    /// day has the newer valid stamp, so the host never overwrites a newer widget-fetched day. Host days are written
    /// without request numbers because the widget numbers its requests with its own counter. Club metadata (`clubs`,
    /// name, short code) comes from the side with the newer valid `metaUpdatedAt` (the host wins a tie). An up-to-date
    /// mirror is not rewritten (identical bytes are skipped).
    private func mergeIntoMirror(_ snap: TimetableSnapshot, now: Date) throws {
        guard let mirrorDirectory else { return }
        let name = Self.snapshotFile(snap.clubId)
        do {
            try flocked(".snapshot-\(snap.clubId).lock", in: mirrorDirectory) {
                let theirs = (try? decoder.decode(TimetableSnapshot.self, from: Data(contentsOf: url(name, in: mirrorDirectory)))).flatMap { $0.clubId == snap.clubId ? $0 : nil }
                var days = theirs?.days ?? [:], stamps = theirs?.daySyncedAt ?? [:], revisions = theirs?.dayRevision ?? [:]
                Self.dropFutureStamps(&stamps, &revisions, now: now)
                // A host day replaces a widget day that is older, or equally old without a widget request number, so an
                // equal-stamp repair never erases the widget's own `dayRevision`.
                // Stamps compare at disk (millisecond) precision, so an in-memory stamp never beats its own stored copy.
                for (day, stamp) in snap.daySyncedAt where stamp <= now.addingTimeInterval(2) && stamps[day].map({ theirs in
                    let (mine, stored) = (Self.persistedDate(stamp), Self.persistedDate(theirs))
                    return mine > stored || (revisions[day] == nil && mine >= stored)
                }) ?? true {
                    days[day] = snap.days[day] ?? []; stamps[day] = stamp; revisions[day] = nil
                }
                let oldest = Self.oldestKeptDay(now: now)
                let keptStamps = stamps.filter { $0.key >= oldest }
                func validMeta(_ s: TimetableSnapshot) -> Date? { s.metaUpdatedAt <= now.addingTimeInterval(2) ? s.metaUpdatedAt : nil }
                // Widget metadata keeps its own request number; host metadata is stored with `metaRevision` 0 (a timestamped
                // cross-store copy that the widget's request counter never compares against).
                // Equal-time identical metadata keeps the widget's copy and its request number.
                var meta = snap, metaRevision: UInt64 = 0
                if let theirs, let theirAt = validMeta(theirs).map(Self.persistedDate), validMeta(snap).map(Self.persistedDate).map({ snapAt in
                    theirAt > snapAt || (theirAt == snapAt && (theirs.clubs, theirs.clubName, theirs.clubShortCode) == (snap.clubs, snap.clubName, snap.clubShortCode))
                }) ?? true { meta = theirs; metaRevision = theirs.metaRevision }
                let merged = TimetableSnapshot(clubs: meta.clubs, clubId: snap.clubId, clubName: meta.clubName, clubShortCode: meta.clubShortCode,
                                               days: days.filter { $0.key >= oldest }, syncedAt: Self.validSyncedAt(keptStamps, fallback: snap.syncedAt, now: now),
                                               daySyncedAt: keptStamps, dayRevision: revisions.filter { $0.key >= oldest }, metaRevision: metaRevision, metaUpdatedAt: min(meta.metaUpdatedAt, now))
                try writeFile(merged, name, in: mirrorDirectory)
            }
        } catch where !mirrorIsExplicit {}
    }

    /// `d` at the precision it is stored with on disk (milliseconds), so in-memory and decoded dates compare exactly.
    static func persistedDate(_ d: Date) -> Date {
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: fmt.string(from: d)) ?? d
    }

    /// The widget payload for `snapshot`, with one row token per active booking whose entries agree on their club and
    /// start: a dated, named booking binds its own club and London date; an unnamed one takes the club, and an undated
    /// one the date, of the one row its ID resolves to across this store's timetables (none when any is unreadable, the
    /// row is on another date, or its club differs from the booking's named one). Others get no token (no badge).
    private func compactMirror(_ snapshot: BookingsSnapshot) -> BookedIdsMirror {
        var stored: EntitledTimetableIndex?
        func storedRow(_ id: Int) -> (row: ClassSession, clubName: String)? {
            if stored == nil {
                let peers = storedSnapshotsUnlocked()
                stored = EntitledTimetableIndex(clubs: peers.corrupt ? [(0, nil)] : peers.snapshots.map { ($0.clubId, $0) })
            }
            guard case .unique(let row, let clubId) = stored?.lookup(id) else { return nil }
            return (row, stored?.clubName(clubId) ?? row.clubName)
        }
        let ids = snapshot.bookedIds.sorted()
        let tokens = ids.compactMap { id -> String? in
            guard let club = snapshot.agreedActiveClub(classId: id) else { return nil }
            switch snapshot.activeStart(classId: id) {
            case .resolved(.exact(let start)):
                let day = LondonCalendar.londonTodayIso(now: start)
                if !club.isEmpty { return Self.widgetRowToken(classId: id, clubName: club, dateIso: day) }
                guard let hit = storedRow(id), hit.row.date == day else { return nil }
                return Self.widgetRowToken(classId: id, clubName: hit.clubName, dateIso: day)
            case .empty:
                guard let hit = storedRow(id), club.isEmpty || [hit.clubName, hit.row.clubName].contains(where: { club.caseInsensitiveCompare($0) == .orderedSame }) else { return nil }
                return Self.widgetRowToken(classId: id, clubName: club.isEmpty ? hit.clubName : club, dateIso: hit.row.date)
            default: return nil
            }
        }
        return BookedIdsMirror(bookedIds: ids, ownerId: MemberSession.opaqueId(snapshot.ownerKey), rowTokens: tokens)
    }

    /// Primary failures always throw; mirror failures follow `writeMirror`.
    private func writeAccount(_ marker: AccountMarker) throws {
        try writeFile(marker, Self.accountFile, in: primaryDirectory)
        if let error = writeMirror(marker.mirror, Self.accountFile) { throw error }
    }

    /// Signed-out state: the widget's `account.json` goes first (so a failed bookings removal still shows no badges),
    /// the primary marker keeps an advanced revision (saturating at `.max`, so sign-out always works; a corrupt marker
    /// is replaced), and every removal is attempted before the first error is thrown. `mirror: false` (mirror lock
    /// unavailable) leaves the widget copies untouched.
    private func clearAccountFiles(mirror: Bool = true) throws {
        var cleared = (try? readMarkerStrict()) ?? AccountMarker()
        cleared.invalidate(); cleared.ownerId = nil
        try attemptAll([
            { if mirror { try self.removeMirrorFiles([Self.accountFile]) } },
            { try self.writeFile(cleared, Self.accountFile, in: self.primaryDirectory) },
            { try self.removeFile(Self.bookingsFile, in: self.primaryDirectory) },
            { if mirror { try self.removeMirrorFiles([Self.bookingsFile]) } },
        ])
    }

    private func removeMirrorFiles(_ names: [String]) throws {
        guard let mirrorDirectory else { return }
        try attemptAll(names.map { name in { try self.removeFile(name, in: mirrorDirectory) } })
    }

    /// Runs every step, so one failed step never skips the rest: whether any succeeded, and the first failure.
    private func runAll(_ steps: [() throws -> Void]) -> (anySucceeded: Bool, firstError: Error?) {
        var any = false, first: Error?
        for step in steps { do { try step(); any = true } catch { first = first ?? error } }
        return (any, first)
    }

    /// `runAll`, then throws the first failure.
    private func attemptAll(_ steps: [() throws -> Void]) throws { if let first = runAll(steps).firstError { throw first } }

    /// Takes the in-process lock by a monotonic deadline (`lockTimeout` from now by default): one unconditional
    /// attempt, then polls `try()` every 2 ms, checking the deadline before and after each sleep; the caller unlocks.
    private func acquireLock(_ name: String = "the store lock", deadline: TimeInterval? = nil) throws {
        let deadline = deadline ?? uptime() + lockTimeout
        while !lock.try() {
            let remaining = deadline - uptime()
            guard remaining > 0 else { throw StoreError.lockTimedOut(name) }
            Thread.sleep(forTimeInterval: min(0.002, remaining))
            guard uptime() < deadline else { throw StoreError.lockTimedOut(name) }
        }
    }

    /// Lenient reads: `fallback` when the in-process lock times out.
    private func withBoundedLock<T>(_ fallback: T, _ body: () -> T) -> T {
        guard (try? acquireLock()) != nil else { return fallback }
        defer { lock.unlock() }
        return body()
    }

    /// One monotonic deadline, taken before waiting, covers the in-process lock and every lock file in `names` (taken
    /// in order, released in reverse).
    private func withFileLock<T>(_ names: String..., body: () throws -> T) throws -> T {
        let deadline = uptime() + lockTimeout
        try acquireLock(names[0], deadline: deadline)
        defer { lock.unlock() }
        func nested(_ rest: ArraySlice<String>) throws -> T {
            guard let name = rest.first else { return try body() }
            return try flocked(name, deadline: deadline) { try nested(rest.dropFirst()) }
        }
        return try nested(names[...])
    }

    private func openLockFile(_ name: String, in folder: URL, permissionCode: CocoaError.Code = .fileWriteNoPermission) throws -> Int32 {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(url(name, in: folder).path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(permissionCode) }
        return fd
    }

    /// Cross-process `flock` on `name` in `dir` (primary by default); the caller already holds `lock`.
    private func flocked<T>(_ name: String, in dir: URL? = nil, deadline: TimeInterval? = nil, _ body: () throws -> T) throws -> T {
        let fd = try lockFile(name, in: dir ?? primaryDirectory, deadline: deadline ?? uptime() + lockTimeout)
        defer { unlockFile(fd) }
        return try body()
    }

    /// Opens and locks `name` in `dir`: one unconditional non-blocking `flock`, then polling every 5 ms with the
    /// monotonic `deadline` checked before and after each sleep (a lock released after it is never taken), then
    /// `StoreError.lockTimedOut`. Returns the locked descriptor for `unlockFile` (`-1` where `flock` is missing).
    private func lockFile(_ name: String, in dir: URL, deadline: TimeInterval) throws -> Int32 {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = try openLockFile(name, in: dir)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK else { close(fd); throw CocoaError(.fileLocking) }
            guard uptime() < deadline else { close(fd); throw StoreError.lockTimedOut(name) }
            usleep(5_000)
            guard uptime() < deadline else { close(fd); throw StoreError.lockTimedOut(name) }
        }
        return fd
        #else
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return -1
        #endif
    }

    private func unlockFile(_ fd: Int32) {
        #if canImport(Darwin) || canImport(Glibc)
        flock(fd, LOCK_UN); close(fd)
        #endif
    }

    private func url(_ name: String, in dir: URL? = nil) -> URL { (dir ?? primaryDirectory).appendingPathComponent(name) }

    /// `nil` only when the file does not exist; unreadable or malformed files throw.
    private func readStrict<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let data: Data
        do { data = try Data(contentsOf: url(name)) } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        return try decoder.decode(type, from: data)
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? { try? readStrict(type, name) }

    /// Skips the write when the file already holds exactly these bytes, so no-op repairs touch nothing on disk.
    private func writeFile<T: Encodable>(_ value: T, _ name: String, in dir: URL) throws {
        let data = try encoder.encode(value), target = url(name, in: dir)
        if (try? Data(contentsOf: target)) == data { return }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// Writes the widget-mirror copy of an account file. A failure is returned when the mirror was injected or a mirror
    /// copy already exists (a stale copy must never silently survive an account change); otherwise it is ignored (no
    /// widget container yet).
    private func writeMirror<M: Encodable>(_ value: M, _ name: String) -> Error? {
        guard let mirrorDirectory else { return nil }
        let strict = mirrorIsExplicit || fileManager.fileExists(atPath: url(name, in: mirrorDirectory).path)
        do { try writeFile(value, name, in: mirrorDirectory); return nil } catch { return strict ? error : nil }
    }

    private func removeFile(_ name: String, in dir: URL) throws {
        if fileManager.fileExists(atPath: url(name, in: dir).path) { try fileManager.removeItem(at: url(name, in: dir)) }
    }

    /// Removes `name` from both directories independently; an existing file that cannot be removed throws after
    /// both removals were attempted.
    private func remove(_ name: String) throws {
        try attemptAll([primaryDirectory, mirrorDirectory].compactMap { $0 }.map { dir in { try self.removeFile(name, in: dir) } })
    }
}
