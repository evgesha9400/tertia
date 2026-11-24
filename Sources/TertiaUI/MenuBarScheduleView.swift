import Foundation
import SwiftUI
import TertiaCore

@MainActor
public final class ScheduleViewModel: ObservableObject {
    @Published public var preferences: TertiaPreferences = TertiaPreferences()
    @Published public var selectedDate: String = LondonCalendar.londonTodayIso() { didSet { selectedDateBox.value = selectedDate } }
    @Published public var snapshot: TimetableSnapshot?
    @Published public var memberSession: MemberSession?
    @Published public var bookings: BookingsSnapshot?
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var themeOverride: ColorScheme? = .dark
    @Published public var isClubMenuOpen = false
    @Published public var isAccountOpen = false
    @Published public var emailInput = ""
    @Published public var passwordInput = ""
    @Published public var isAuthBusy = false
    @Published public var busyClassId: Int?
    @Published public var confirmLateCancelId: Int?
    @Published public var bannerMessage: String?
    @Published public var bannerIsError = false
    /// Fixed clock for previews and tests; `nil` means booking checks use the time of the click.
    public var nowOverride: Date?

    public static let noClubsMessage = "No timetable clubs available on this membership."
    public static let staleIntentMessage = "Booking state changed. Review the updated button."
    public static let lateConfirmMessage = "3h or less before start: tap confirm for late cancel."

    private let client: PublicTimetableClient
    private let bookingClient: MobileBookingClient
    private let store: SharedStateStore
    private let keychain: KeychainStore
    private let onStateChanged: (@Sendable () -> Void)?
    /// Bumped by every `load`; only the newest load may write `snapshot`, `errorMessage`, or `isLoading`.
    private var loadGeneration: UInt64 = 0
    /// Bumped by sign-in, sign-out, every class action, and any observed account change; a bookings refresh that
    /// started under an older generation never overwrites `bookings`.
    private var bookingsGeneration: UInt64 = 0
    /// Account that armed `confirmLateCancelId`; a confirmation never carries over to another account.
    private var confirmLateCancelOwnerKey: String?
    /// Active booking entries of the class when the confirmation was armed; a confirmation never carries over to another
    /// booking under the same class ID (a replaced class, start, or club).
    private var confirmLateCancelEntries: [MemberBooking]?
    /// `selectedDate`, readable off the main actor, so a class action waiting on `.mutation.lock` sees a day switch made
    /// meanwhile and is refused before anything is sent.
    private let selectedDateBox = DateBox(LondonCalendar.londonTodayIso())
    /// Set when `syncFromDisk` arrives during sign-in or a class action; flushed as soon as that operation ends.
    private var hasPendingDiskSync = false
    private var clubCatalog = Club.defaultClubs
    private var signedOutCatalog = Club.defaultClubs
    /// Why the last club realignment could not be saved; `signIn` reports it instead of a plain success banner.
    private var alignmentSaveError: Error?
    /// Widget-copy failure of the last club realignment; `signIn` reports it instead of a plain success banner.
    private var alignmentMirrorError: Error?

    public init(store: SharedStateStore = SharedStateStore(), keychain: KeychainStore = KeychainStore(), client: PublicTimetableClient? = nil, bookingClient: MobileBookingClient = MobileBookingClient(), onStateChanged: (@Sendable () -> Void)? = nil) {
        self.store = store
        self.keychain = keychain
        self.client = client ?? PublicTimetableClient(store: store)
        self.bookingClient = bookingClient
        self.onStateChanged = onStateChanged
        reloadLocalState(autoLoad: false)
    }

    /// Sign-in and class actions own the account state while they run; a public timetable load does not.
    private var isAccountBusy: Bool { isAuthBusy || busyClassId != nil }

    /// Reloads disk state now, or right after a running sign-in or class action. A running public load never defers
    /// it: when the reload changes the club or account, that load's late result is discarded.
    public func syncFromDisk() {
        guard !isAccountBusy else { hasPendingDiskSync = true; return }
        hasPendingDiskSync = false
        reloadLocalState()
    }

    /// Menu appearance: reloads disk state without scheduling a timetable load of its own, because the view runs exactly
    /// one `load(forceRefresh: false)` right after (one public request on a cold cache, never two).
    public func handleAppear() {
        guard !isAccountBusy else { hasPendingDiskSync = true; return }
        hasPendingDiskSync = false
        reloadLocalState(autoLoad: false)
    }

    private func flushPendingDiskSync() {
        guard hasPendingDiskSync, !isAccountBusy else { return }
        hasPendingDiskSync = false
        reloadLocalState()
    }

    /// Discards every in-flight public load: its result can no longer write `snapshot`, `errorMessage`, or `isLoading`.
    private func invalidateLoads() { loadGeneration &+= 1; isLoading = false }

    /// Re-reads preferences, the Keychain session, its bookings, and caches with zero private calls, all from one locked
    /// read (`alignPreferencesToCurrentAccount`, which also realigns the club to that account), so an account switch
    /// mid-reload never shows one account's name with another's bookings. Any account change (including one made by the
    /// CLI) resets inputs, confirmations, and banners belonging to the previous account. An unreadable state shows the
    /// menu signed out with an error. When the club changed or the shown date is not cached, the stale error is cleared
    /// and the public timetable loads (`autoLoad`, cache-aware).
    private func reloadLocalState(autoLoad: Bool = true) {
        let todayIso = LondonCalendar.londonTodayIso()
        if selectedDate < todayIso { selectedDate = todayIso }
        let previousClubId = preferences.clubId
        let result = Result { try store.alignPreferencesToCurrentAccount(keychain: keychain) }
        let state = try? result.get()
        let saved = state?.session
        let accountChanged = (saved?.ownerKey, saved?.token) != (memberSession?.ownerKey, memberSession?.token)
        if accountChanged {
            clearLateConfirm(); passwordInput = ""; emailInput = saved?.email ?? ""; bannerMessage = nil
            bookingsGeneration &+= 1
        }
        memberSession = saved
        bookings = state?.bookings
        switch result {
        case .success(let read):
            // The locked read's catalog: the 17 public clubs when signed out, the public catalog when signed in.
            if read.session == nil { signedOutCatalog = read.catalog } else { clubCatalog = read.catalog }
            if let warning = read.warning { showBanner(warning.localizedDescription, isError: true) }
            alignmentSaveError = nil; alignmentMirrorError = nil
            adoptAlignment((read.preferences, read.alignment, read.mirrorError))
            // `adoptAlignment` already loaded a changed club's snapshot; an unchanged club is re-read here (once).
            if read.alignment != .noneEntitled, preferences.clubId == previousClubId { snapshot = store.loadSnapshot(clubId: preferences.clubId) }
            // Upgrades legacy account files and repairs the widget mirror (or clears it when signed out), offline.
            persist("sync local account files") { if let mirrorError = try store.reconcileAccountMirror(for: read.session, keychain: keychain) { showMirrorWarning(mirrorError) } }
        case .failure(let error):
            // Unreadable Keychain item or account files: keep them on disk, stay signed out in the UI, and tell the user.
            // The menu shows the signed-out 17-club picker, so a saved extra club displays as Canary Wharf (39) in memory
            // only; the unreadable account's preferences stay untouched on disk.
            refreshClubCatalogs()
            var shown = store.loadPreferences()
            if !Club.defaultClubs.contains(where: { $0.id == shown.clubId }) {
                let fallback = signedOutCatalog.first { $0.id == 39 } ?? Club(id: 39, name: "Canary Wharf", shortCode: "CANARY")
                shown.clubId = fallback.id; shown.clubName = fallback.name; shown.clubShortCode = fallback.shortCode
            }
            preferences = shown
            snapshot = store.loadSnapshot(clubId: preferences.clubId)
            if let kcError = error as? KeychainError {
                let detail = kcError.localizedDescription.hasSuffix(".") ? String(kcError.localizedDescription.dropLast()) : kcError.localizedDescription
                showBanner(kcError.isACLRejection || kcError == .invalidData ? kcError.localizedDescription : "Saved sign-in unreadable (\(detail)). Sign in again.", isError: true)
            } else {
                showBanner("Could not read the saved account state: \(error.localizedDescription)", isError: true)
            }
        }
        let clubChanged = preferences.clubId != previousClubId
        if accountChanged || clubChanged { invalidateLoads() }
        guard autoLoad, !hasNoEntitledClubs, clubChanged || snapshot?.hasCachedDay(effectiveSelectedDate()) != true else { return }
        errorMessage = nil
        Task { await load(forceRefresh: false) }
    }

    private func refreshClubCatalogs() { clubCatalog = store.publicClubCatalog(); signedOutCatalog = store.signedOutClubCatalog() }

    /// All 17 clubs when signed out; the account's timetable clubs when signed in.
    public var availableClubs: [Club] { memberSession.map { $0.entitledClubs(from: clubCatalog) } ?? signedOutCatalog }

    private var hasNoEntitledClubs: Bool { memberSession != nil && availableClubs.isEmpty }

    /// `false` while signed in with a selected club outside the account's timetable clubs (a failed realignment save).
    private var isSelectedClubAllowed: Bool { memberSession == nil || availableClubs.contains { $0.id == preferences.clubId } }

    /// Booking actions need a session, known bookings, and an entitled club.
    public var canUseBookingActions: Bool { memberSession != nil && bookings != nil && !hasNoEntitledClubs }

    /// Whether the late confirmation armed for `classId` still belongs to this account and to the same booking entries.
    public func isConfirmingLateCancel(_ classId: Int) -> Bool {
        confirmLateCancelId == classId && confirmLateCancelOwnerKey == memberSession?.ownerKey
            && confirmLateCancelEntries != nil && bookings?.activeEntries(classId: classId) == confirmLateCancelEntries
    }

    /// The date the menu shows: `selectedDate`, or London today once midnight has passed it.
    public func effectiveSelectedDate(now: Date = Date()) -> String { max(selectedDate, LondonCalendar.londonTodayIso(now: now)) }

    /// After London midnight in an open menu, moves the selection to today and reloads the public timetable (cache-aware,
    /// zero private API calls). Does nothing while the selection is today or later.
    public func rolloverMidnightIfNeeded(now: Date = Date()) async {
        let todayIso = LondonCalendar.londonTodayIso(now: now)
        guard selectedDate < todayIso else { return }
        selectedDate = todayIso; clearLateConfirm()
        await load(forceRefresh: false)
    }

    /// The stored timetables of the account's clubs, read once per render pass (`nil` when signed out), so every card
    /// of one pass resolves class IDs against one state.
    public func entitledTimetableIndex() -> SharedStateStore.EntitledTimetableIndex? {
        memberSession != nil ? store.loadEntitledTimetables(clubIds: Set(availableClubs.map(\.id))) : nil
    }

    /// `[row.id: start]` for the rows of `rows` this member's booking matches (`matchedRowStarts`), so a booking at one
    /// club or day never keeps a same-ID row of another club or day on screen.
    private func matchedStarts(_ rows: [ClassSession], index: SharedStateStore.EntitledTimetableIndex?) -> [Int: Date] {
        guard let bookings else { return [:] }
        let index = index ?? entitledTimetableIndex()
        return bookings.matchedRowStarts(for: rows, clubId: preferences.clubId, clubName: preferences.clubName) { index?.lookup($0) ?? .missing }
    }

    /// Rows of the shown date; a booked row stays until its booking's own start, whatever its public wall time says.
    public func filteredClasses(index: SharedStateStore.EntitledTimetableIndex? = nil, now: Date = Date()) -> [ClassSession] {
        guard let snapshot, snapshot.clubId == preferences.clubId, isSelectedClubAllowed else { return [] }
        let day = effectiveSelectedDate(now: now), rows = snapshot.classes(for: day)
        return LondonCalendar.filterSessions(rows, period: preferences.period, search: preferences.searchQuery, selectedDate: day,
                                             now: now, activeBookingStarts: matchedStarts(rows, index: index))
    }

    /// Redraw instants of the shown date (`LondonCalendar.upcomingBoundaryDates` with the row-matched booking starts).
    public func upcomingBoundaryDates(index: SharedStateStore.EntitledTimetableIndex? = nil, now: Date = Date()) -> [Date] {
        let rows = snapshot?.classes(for: effectiveSelectedDate(now: now)) ?? []
        return LondonCalendar.upcomingBoundaryDates(for: rows, now: now, activeBookingStarts: matchedStarts(rows, index: index))
    }

    /// What a class card shows for `session`: whether this row is the booked class (`matchesDisplayedRow`, so a same-ID
    /// class at another club or on another day is never badged), whether a booked row may still be cancelled, and
    /// whether its badge is a button right now. Both use the cross-club lookup and `BookingAuthorization` rules that
    /// `handleClassAction` runs, so an ambiguous or untrusted class never offers a BOOK or CANCEL button. A BOOK button,
    /// or a CANCEL button relying on the public row (an undated booking), also needs the stored row to still be this
    /// drawn row (club, date, start, title), so a card drawn from an older loaded timetable never acts.
    public func cardInputs(for session: ClassSession, index: SharedStateStore.EntitledTimetableIndex? = nil,
                           now: Date = Date()) -> (isBooked: Bool, canCancelBooked: Bool, canAct: Bool) {
        let index = index ?? entitledTimetableIndex()
        let lookup = index?.lookup(session.id) ?? .missing
        let isBooked = bookings?.matchesDisplayedRow(session, clubId: preferences.clubId, clubName: preferences.clubName, lookup: lookup) == true
        let locked = isAuthBusy || (busyClassId != nil && busyClassId != session.id)
        let enabled = canUseBookingActions && !locked
        var storedRowIsDrawn: Bool {
            guard case .unique(let stored, let clubId) = lookup else { return false }
            return clubId == preferences.clubId && stored.date == session.date && stored.startTime == session.startTime && stored.title == session.title
        }
        guard !isBooked else {
            let canCancel = BookingAuthorization.canCancel(classId: session.id, bookings: bookings, now: now) {
                try store.fallbackPublicTarget(lookup, classId: session.id)
            }
            let undated = bookings?.activeStart(classId: session.id) == .empty
            return (true, canCancel, enabled && canCancel && (!undated || storedRowIsDrawn))
        }
        let canBook = enabled && storedRowIsDrawn && (try? BookingAuthorization.authorizeBooking(classId: session.id, lookup: lookup, bookings: bookings, now: now,
                                                                                                 expectedClubId: preferences.clubId)) != nil
        return (false, false, canBook)
    }

    /// The action of the badge drawn for `session` at `now` (`nil` when the badge is not a button). It captures, at draw
    /// time, what the badge shows (book, cancel, or the late confirmation), the session token, the club, the row's date,
    /// start, and title, and (for a cancellation) the booking's active entries, so a later call is refused (zero private
    /// requests) once any of them changed. `inputs` reuses the card's own `cardInputs` result.
    public func classAction(for session: ClassSession, index: SharedStateStore.EntitledTimetableIndex? = nil,
                            inputs: (isBooked: Bool, canCancelBooked: Bool, canAct: Bool)? = nil, now: Date = Date()) -> (@MainActor () async -> Void)? {
        let inputs = inputs ?? cardInputs(for: session, index: index, now: now)
        guard inputs.canAct else { return nil }
        let intentCancel = inputs.isBooked, token = memberSession?.token ?? "", owner = memberSession?.ownerKey, clubId = preferences.clubId
        let confirming = isConfirmingLateCancel(session.id)
        let expectedBookings = intentCancel ? bookings?.activeEntries(classId: session.id) ?? [] : nil
        return { [weak self] in
            await self?.handleClassAction(classId: session.id, expectedCancel: intentCancel, expectedToken: token, expectedClubId: clubId, title: session.title,
                                          startTime: session.startTime, expectedDate: session.date, expectedConfirmedLate: confirming,
                                          expectedBookings: expectedBookings, expectedOwnerKey: owner)
        }
    }

    /// The badge the menu draws for `session` at `now` (used by previews and tests).
    public func badge(for session: ClassSession, index: SharedStateStore.EntitledTimetableIndex? = nil, now: Date = Date()) -> CompactClassCard.Badge {
        let inputs = cardInputs(for: session, index: index, now: now)
        return CompactClassCard.badge(status: LondonCalendar.bookingWindowStatus(for: session, now: now), isBooked: inputs.isBooked, canCancelBooked: inputs.canCancelBooked,
                                      confirmingLateCancel: isConfirmingLateCancel(session.id), isBusy: busyClassId == session.id, hasAction: inputs.canAct)
    }

    /// `false` when the shown date was never fetched for the selected club (as opposed to a fetched day with no classes).
    public func isShownDayCached(now: Date = Date()) -> Bool {
        snapshot?.clubId == preferences.clubId && snapshot?.hasCachedDay(effectiveSelectedDate(now: now)) == true
    }

    /// Text of an empty class list: the shown date was never fetched, a period or search filter hides classes still to
    /// come, every class of the day has started, or the fetched day has no classes at all.
    public func emptyScheduleMessage(index: SharedStateStore.EntitledTimetableIndex? = nil, now: Date = Date()) -> String {
        guard isShownDayCached(now: now) else { return "Schedule not loaded for this date." }
        let day = effectiveSelectedDate(now: now), allDayRows = snapshot?.classes(for: day) ?? []
        let hasFilter = preferences.period != .all || !preferences.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let unfilteredRemaining = LondonCalendar.filterSessions(allDayRows, period: .all, search: "", selectedDate: day, now: now,
                                                                activeBookingStarts: matchedStarts(allDayRows, index: index))
        if hasFilter && !unfilteredRemaining.isEmpty { return "No classes match this filter." }
        return allDayRows.isEmpty ? "No classes scheduled for this date." : "No more classes today."
    }

    /// Footer status: never claims a sync time the shown date does not have.
    public func footerStatusText(count: Int, now: Date = Date()) -> String {
        if isLoading { return "\(count) CLASSES · SYNCING..." }
        guard let synced = snapshot?.syncedAt(for: effectiveSelectedDate(now: now)) else { return "\(count) CLASSES · NOT SYNCED" }
        return "\(count) CLASSES · SYNCED \(LondonCalendar.formatSyncTime(synced))"
    }

    /// Timetable always loads from the public website (`bypassPublicCache` or `forceRefresh` skip the cache). Only
    /// `forceRefresh` (the header Refresh button) also syncs bookings: that private sync starts after the public fetch,
    /// and only while the Keychain still holds the account that was signed in when the load began. A public failure never
    /// skips it, a sign-out or account switch during the fetch cancels it (zero private requests), and its failure never
    /// discards a fresh timetable. A member without timetable clubs gets a public club discovery fetch on a cache bypass.
    public func load(forceRefresh: Bool = false, bypassPublicCache: Bool = false) async {
        let bypass = forceRefresh || bypassPublicCache
        if bypass && isLoading { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let clubId = preferences.clubId, date = effectiveSelectedDate(), startMember = memberSession
        isLoading = true
        if bypass { bannerMessage = nil }
        defer {
            if generation == loadGeneration { isLoading = false }
            flushPendingDiskSync()
        }
        if hasNoEntitledClubs {
            if bypass, await discoverEntitledClub(generation: generation) {
                await load(forceRefresh: false)
            } else if generation == loadGeneration {
                snapshot = nil; errorMessage = Self.noClubsMessage
            }
        } else {
            errorMessage = nil
            do {
                let fresh = try await client.fetchSchedule(clubId: clubId, date: date, forceRefresh: bypass)
                refreshClubCatalogs()
                if generation == loadGeneration, fresh.clubId == preferences.clubId {
                    snapshot = fresh
                    if preferences.clubName != fresh.clubName || preferences.clubShortCode != fresh.clubShortCode {
                        updatePrefs { if $0.clubId == fresh.clubId { $0.clubName = fresh.clubName; $0.clubShortCode = fresh.clubShortCode } }
                    }
                }
            } catch {
                if generation == loadGeneration {
                    errorMessage = error.localizedDescription
                    if snapshot != nil { showBanner(error.localizedDescription, isError: true) }
                }
            }
        }
        if forceRefresh, let member = startMember, isShown(member) {
            if let live = try? keychain.readSession(), live.token == member.token, live.ownerKey == member.ownerKey { await syncBookings(for: member) } else { reloadLocalState() }
        }
        onStateChanged?()
    }

    /// The `Retry` button of an unavailable schedule: the public timetable only, bypassing its cache (zero private calls;
    /// bookings sync only from the header Refresh button).
    public func retryPublicSchedule() async { await load(forceRefresh: false, bypassPublicCache: true) }

    /// One public page (`public-clubs.json` refresh) for a member without known timetable clubs; selects a newly
    /// entitled club. Returns whether the selected club is now one of the account's timetable clubs.
    private func discoverEntitledClub(generation: UInt64) async -> Bool {
        do { _ = try await client.fetchSchedule(clubId: Club.defaultClubs.first?.id ?? 39, date: LondonCalendar.londonTodayIso(), forceRefresh: true) }
        catch {
            // A newer load or account change superseded this discovery: its failure is no longer news.
            if generation == loadGeneration { showBanner("Could not refresh the public club list: \(error.localizedDescription)", isError: true) }
            return false
        }
        guard generation == loadGeneration else { return false }
        refreshClubCatalogs()
        guard memberSession != nil, !hasNoEntitledClubs else { return false }
        applyClubAlignment()
        return isSelectedClubAllowed
    }

    /// Assigns the result only if no account change or class action happened while the request was in flight; errors
    /// from such a stale request are dropped unless the token itself was rejected. Returns (and shows) a failed
    /// widget-mirror write of the assigned bookings.
    @discardableResult
    private func syncBookings(for member: MemberSession) async -> Error? {
        let generation = bookingsGeneration
        do {
            let synced = try await bookingClient.syncBookings(for: member, store: store, keychain: keychain)
            guard generation == bookingsGeneration, isShown(member) else { return nil }
            bookings = synced.snapshot
            if let mirrorError = synced.mirrorError { showMirrorWarning(mirrorError) }
            return synced.mirrorError
        } catch {
            if generation != bookingsGeneration, !BookingClientError.isUnauthorized(error) { return nil }
            handleBookingError(error, for: member)
            return nil
        }
    }

    public func signIn() async {
        guard !isAuthBusy, busyClassId == nil else { return }
        let email = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !passwordInput.isEmpty else {
            showBanner("Enter your Third Space email and password.", isError: true); return
        }
        isAuthBusy = true
        defer { isAuthBusy = false; flushPendingDiskSync() }
        bannerMessage = nil
        let session: MemberSession, committed: (cacheError: Error?, warning: KeychainError?)
        // Keychain warnings of the begin and commit reads; every banner this sign-in shows names them.
        var warnings: [KeychainError] = []
        do {
            let started = try store.beginLogin(keychain: keychain)
            if let warning = started.warning { warnings.append(warning) }
            session = try await bookingClient.login(email: email, password: passwordInput)
            committed = try store.commitLogin(session, attempt: started.attempt, keychain: keychain)
            if let warning = committed.warning, !warnings.contains(warning) { warnings.append(warning) }
        } catch {
            if (error as? BookingClientError) == .sessionSuperseded { // a sign-out or another sign-in completed meanwhile: show it
                reloadLocalState(); showBanner(error.localizedDescription, warnings: warnings, isError: false); return
            }
            if case .previousSessionLost? = error as? KeychainError { showSignedOut() } // the old credential is gone: show signed out
            showBanner(error.localizedDescription, warnings: warnings, isError: true); return
        }
        bookingsGeneration &+= 1
        memberSession = session; bookings = nil; passwordInput = ""; clearLateConfirm()
        let needsLoad = applyClubAlignment()
        let alignmentError = alignmentSaveError, alignmentMirror = alignmentMirrorError
        onStateChanged?()
        let syncMirror = await syncBookings(for: session)
        let cacheProblem = committed.cacheError.map { "clearing the previous account's cached bookings failed: \($0.localizedDescription)" }
        /// A failed sync (its banner is already shown) or a takeover by another account still names the commit's problems.
        func appendCommitProblems() {
            guard cacheProblem != nil || !warnings.isEmpty else { return }
            showBanner([bannerMessage, cacheProblem.map { "Signed in, but \($0)" }].compactMap { $0 }.joined(separator: " "), warnings: warnings, isError: true)
        }
        guard isShown(session) else { appendCommitProblems(); return }
        if needsLoad { await load(forceRefresh: false) }
        isAccountOpen = false
        if bookings != nil {
            let problems = ([cacheProblem] + warnings.map(\.localizedDescription) + [alignmentError.map { "saving this account's club failed: \($0.localizedDescription)" },
                            (alignmentMirror ?? syncMirror).map { "updating the widget copy failed: \($0.localizedDescription)" }]).compactMap { $0 }
            if problems.isEmpty { showBanner("Signed in as \(session.firstName)", isError: false) }
            else { showBanner("Signed in as \(session.firstName), but \(problems.joined(separator: "; "))", isError: true) }
        } else { appendCommitProblems() }
        onStateChanged?()
    }

    /// Deletes the Keychain credential first (only while it is still this menu's account); once that succeeds the UI is
    /// signed out even if cache cleanup fails. When another process already signed out or switched accounts, nothing
    /// is removed and the menu reloads that state.
    public func signOut() {
        guard !isAuthBusy, busyClassId == nil else { return }
        guard let member = memberSession else { reloadLocalState(); return }
        let result: (didClear: Bool, cacheError: Error?, warning: KeychainError?)
        do { result = try store.clearSession(expectedSession: member, keychain: keychain) } catch {
            showBanner("Could not sign out: \(error.localizedDescription)", isError: true); return
        }
        let warnings = result.warning.map { [$0] } ?? []
        guard result.didClear else {
            reloadLocalState()
            showBanner("The account was already changed by another Tertia process; nothing was removed.", warnings: warnings, isError: false)
            return
        }
        isAccountOpen = false
        showSignedOut()
        if let cacheError = result.cacheError { showBanner("Signed out, but clearing cached bookings failed: \(cacheError.localizedDescription)", warnings: warnings, isError: true) }
        else { showBanner(warnings.isEmpty ? "Signed out. Keychain token cleared." : "Signed out.", warnings: warnings, isError: false) }
    }

    /// Shows the signed-out state right after this menu's credential was removed (sign-out, a cleared expiry, or a lost
    /// previous credential during sign-in): drops the session, its bookings, and both form fields, then adopts the
    /// store's realigned signed-out club, the 17-club catalog, and that club's snapshot (one locked read) before other
    /// surfaces are notified, and loads the club when it changed.
    private func showSignedOut() {
        memberSession = nil; bookings = nil; emailInput = ""; passwordInput = ""; clearLateConfirm()
        bookingsGeneration &+= 1
        let needsLoad = applyClubAlignment()
        onStateChanged?()
        if needsLoad { Task { await load(forceRefresh: false) } }
    }

    /// Runs the action the clicked button showed. `expectedCancel`, `expectedToken`, and `expectedClubId` are captured
    /// when the button is drawn; if the account, the booked state, the selected club, or the selected day
    /// (`expectedDate`, checked again under `.mutation.lock`, so a day switch while the action waits is refused too)
    /// changed since, the click is refused with zero private requests and the menu reloads. A Cancel button also captures
    /// the booking's active entries (`expectedBookings`): once they differ (a replaced class under the same ID), before
    /// or under the lock, the click is refused the same way. The row's
    /// `expectedDate`, `startTime`, and `title` are captured too: a booking whose row was rescheduled or retitled since,
    /// a cancellation whose booking no longer belongs to the drawn row (`matchesDisplayedRow`), or one whose undated
    /// booking relies on a public row that moved, is refused the same way, before the lock (loaded state) and again
    /// under it (stored state). A first tap on a cancellation 3h or less before start only arms the late confirmation;
    /// `expectedConfirmedLate` is whether the clicked button was the drawn `LATE (<=3H) · CONFIRM?` one, so only a click
    /// on that button can send a late cancellation (a second call of the original Cancel callback is refused with zero
    /// private requests and leaves the confirmation armed). Every other check runs inside `mutateAndSync` after
    /// `.mutation.lock` is held, on live disk state: the Keychain session, its valid bookings, the saved club (still
    /// `expectedClubId`, for book and cancel alike), and the class found by the shared cross-club lookup over its
    /// entitled clubs (a booking must be unique and in the saved club; a cancellation consults it only when the active
    /// booking carries no start of its own).
    public func handleClassAction(classId: Int, expectedCancel: Bool, expectedToken: String, expectedClubId: Int, title: String, startTime: String,
                                  expectedDate: String, expectedConfirmedLate: Bool = false, expectedBookings: [MemberBooking]? = nil,
                                  expectedOwnerKey: String? = nil) async {
        guard busyClassId == nil, !isAuthBusy else { return }
        let confirmedLate = isConfirmingLateCancel(classId)
        guard confirmedLate == expectedConfirmedLate else {
            showBanner(confirmedLate ? Self.lateConfirmMessage : Self.staleIntentMessage, isError: !confirmedLate); return
        }
        let fixedNow = nowOverride, staleMessage = Self.staleIntentMessage, dateBox = selectedDateBox
        let shownRow: @Sendable (ClassSession) -> Bool = { $0.startTime == startTime && $0.title == title && $0.date == expectedDate }
        /// Whether `bookings` still holds the active entries the clicked Cancel was drawn for (`nil`: nothing captured).
        let sameEntries: @Sendable (BookingsSnapshot?) -> Bool = { bookings in
            expectedBookings.map { !$0.isEmpty && bookings?.activeEntries(classId: classId) == $0 } ?? true
        }
        /// The public row an undated booking's cancellation is judged by must still be the drawn row in the drawn club.
        let fallbackRow: @Sendable (SharedStateStore.EntitledClassLookup, [Int: String]) throws -> BookingAuthorization.PublicTarget? = { lookup, clubNames in
            guard let target = try BookingAuthorization.publicTarget(lookup, classId: classId, clubNames: clubNames) else { return nil }
            guard target.clubId == expectedClubId, shownRow(target.session) else { throw BookingDenied(staleMessage) }
            return target
        }
        /// Whether `bookings` still books the drawn row of the clicked club (cancellations only).
        let drawnRowBooked: @Sendable (BookingsSnapshot?, SharedStateStore.EntitledClassLookup, String, ClassSession?) -> Bool = { bookings, lookup, clubName, loaded in
            var candidates = [loaded]
            if case .unique(let row, _) = lookup { candidates.append(row) }
            let row = candidates.compactMap { $0 }.first { $0.id == classId && shownRow($0) } ?? ClassSession(
                id: classId, date: expectedDate, startTime: startTime,
                endTime: "", durationMinutes: 0, title: title, trainer: "", clubName: clubName)
            return bookings?.matchesDisplayedRow(row, clubId: expectedClubId, clubName: clubName, lookup: lookup) == true
        }
        let entryLookup = memberSession != nil ? store.lookupEntitledClass(classId, clubIds: Set(availableClubs.map(\.id))) : .missing
        let stillDrawn = expectedCancel ? drawnRowBooked(bookings, entryLookup, preferences.clubName, liveClassRow(classId))
                                        : bookings?.bookedIds.contains(classId) != true && liveClassRow(classId).map(shownRow) != false
        guard (memberSession?.token ?? "") == expectedToken, expectedOwnerKey.map({ $0 == memberSession?.ownerKey }) ?? true, preferences.clubId == expectedClubId, stillDrawn, sameEntries(bookings),
              effectiveSelectedDate(now: fixedNow ?? Date()) == expectedDate else {
            reloadLocalState()
            showBanner(Self.staleIntentMessage, isError: true); return
        }
        guard let member = memberSession else { isAccountOpen = true; return }
        let bookedTitle = expectedCancel ? bookings?.activeTitle(classId: classId) : nil
        if expectedCancel {
            do {
                let decision = try BookingAuthorization.authorizeCancellation(classId: classId, bookings: bookings, confirmedLate: confirmedLate, now: fixedNow ?? Date()) {
                    try fallbackRow(entryLookup, store.clubNamesById())
                }
                if decision == .needsLateConfirmation {
                    confirmLateCancelId = classId; confirmLateCancelOwnerKey = member.ownerKey; confirmLateCancelEntries = bookings?.activeEntries(classId: classId)
                    showBanner(Self.lateConfirmMessage, isError: false); return
                }
            } catch let denied as BookingDenied where denied.message == Self.staleIntentMessage {
                reloadLocalState(); showBanner(Self.staleIntentMessage, isError: true); return
            } catch { showBanner(error.localizedDescription, isError: true); return }
        }
        clearLateConfirm()
        busyClassId = classId
        bookingsGeneration &+= 1
        defer { busyClassId = nil; flushPendingDiskSync() }
        do {
            let outcome = try await bookingClient.mutateAndSync(classId: classId, isCancel: expectedCancel, session: member, store: store, keychain: keychain) { live, liveBookings, store in
                guard (liveBookings?.bookedIds.contains(classId) == true) == expectedCancel, sameEntries(liveBookings),
                      max(dateBox.value, LondonCalendar.londonTodayIso(now: fixedNow ?? Date())) == expectedDate else { throw BookingDenied(staleMessage) }
                let livePrefs = try store.readPreferences()
                guard livePrefs.clubId == expectedClubId else { throw BookingDenied(staleMessage) }
                let lookup = store.lookupEntitledClass(classId, clubIds: Set(live.entitledClubs(from: store.publicClubCatalog()).map(\.id)))
                guard !expectedCancel else {
                    guard drawnRowBooked(liveBookings, lookup, livePrefs.clubName, nil) else { throw BookingDenied(staleMessage) }
                    // `authorize` consults the public row only for an undated booking; that row must still be the drawn one.
                    let clubNames = store.clubNamesById()
                    if liveBookings?.activeStart(classId: classId) == .empty { _ = try fallbackRow(lookup, clubNames) }
                    return try BookingAuthorization.authorize(classId: classId, isCancel: true, bookings: liveBookings, confirmedLate: confirmedLate,
                                                              now: fixedNow ?? Date(), clubNames: clubNames) { lookup }
                }
                // One lookup: an ambiguous ID is refused by `authorizeBooking`; a unique row must still be the drawn one in the saved club.
                if case .unique(let row, let clubId) = lookup { guard clubId == expectedClubId, shownRow(row) else { throw BookingDenied(staleMessage) } }
                return try BookingAuthorization.authorize(classId: classId, isCancel: false, bookings: liveBookings, confirmedLate: confirmedLate,
                                                          now: fixedNow ?? Date()) { lookup }
            }
            guard isShown(member) else { return }
            let done = expectedCancel ? "Cancelled \(bookedTitle ?? title)" : "Booked \(title) at \(startTime)"
            switch outcome {
            case .synced(let snap, let mirrorError):
                bookings = snap
                if let mirrorError { showBanner("\(done), but updating the widget copy failed: \(mirrorError.localizedDescription)", isError: true) }
                else { showBanner(done, isError: false) }
            case .acceptedRefreshFailed(let error, let followUp):
                let detail: String
                switch followUp {
                case .sessionExpired(let expiry): expireLocally(member, outcome: expiry); detail = expiry.summary
                case .cacheCleanup(let cleanup):
                    if cleanup == .superseded { reloadLocalState() } // load the replacement account's session and cache
                    else { bookings = nil } // actions stay disabled until a Refresh succeeds
                    detail = cleanup.summary
                }
                showBanner("\(done), but refreshing bookings failed: \(error.localizedDescription) \(detail)".trimmingCharacters(in: .whitespaces), isError: true)
            }
            onStateChanged?()
        } catch let denied as BookingDenied where denied.message == Self.staleIntentMessage {
            reloadLocalState(); showBanner(Self.staleIntentMessage, isError: true)
        } catch {
            // A failure after dispatch (lost reply) left the cache invalid on disk: drop the stale bookings now so an
            // already-open menu disables its BOOK and CANCEL buttons, and tell the other surfaces.
            if isShown(member) {
                let onDisk = store.loadBookings(for: member)
                if onDisk != bookings { bookings = onDisk; onStateChanged?() }
            }
            handleBookingError(error, for: member)
        }
    }

    /// The one row with `classId` across the loaded timetable of the selected club (`nil` when missing, ambiguous, or
    /// the loaded snapshot belongs to another club).
    private func liveClassRow(_ classId: Int) -> ClassSession? {
        guard let snapshot, snapshot.clubId == preferences.clubId else { return nil }
        return snapshot.session(id: classId)
    }

    /// Saves the club only if the account in the Keychain may use it (checked and saved in one locked step); a Keychain
    /// warning of that read is shown with any widget-copy failure.
    public func selectClub(_ club: Club) {
        savePrefs {
            guard let selected = try store.selectEntitledClub(clubId: club.id, keychain: keychain) else {
                throw BookingDenied("\(club.name) is not available to the signed-in account.")
            }
            return (try store.readPreferences(), selected.mirrorError, selected.warning)
        }
    }

    public func selectPeriod(_ period: SchedulePeriod) { updatePrefs { $0.period = period } }
    public func updateSearch(_ query: String) { updatePrefs { $0.searchQuery = query } }

    /// Date pills are locked while a class action or sign-in runs, so the shown day never changes under a pending action.
    public var isDaySwitchLocked: Bool { isAccountBusy }

    public func selectDate(_ dateIso: String) {
        isClubMenuOpen = false; clearLateConfirm(); selectedDate = dateIso
        Task { await load(forceRefresh: false) }
    }

    public func toggleTheme() { themeOverride = (themeOverride == .light) ? .dark : .light }

    /// Persists through the cross-process `updatePreferences` first and adopts the committed result; a failed save keeps
    /// the current preferences, skips `onStateChanged`, and shows an error, while a failed widget-mirror write keeps the
    /// committed change and shows a warning. A club change discards in-flight loads, swaps in that club's cached
    /// snapshot (or none), and loads it, never showing the old club's rows.
    private func updatePrefs(_ mutate: (inout TertiaPreferences) -> Void) { savePrefs { let saved = try store.updatePreferences(mutate); return (saved.preferences, saved.mirrorError, nil) } }

    private func savePrefs(_ save: () throws -> (preferences: TertiaPreferences, mirrorError: Error?, warning: KeychainError?)) {
        isClubMenuOpen = false
        let previousClubId = preferences.clubId
        do {
            let saved = try save()
            preferences = saved.preferences
            let warnings = saved.warning.map { [$0] } ?? []
            if let mirrorError = saved.mirrorError { showBanner("Saved, but updating the widget copy failed: \(mirrorError.localizedDescription)", warnings: warnings, isError: true) }
            else if !warnings.isEmpty { showBanner("Saved.", warnings: warnings, isError: true) }
        } catch {
            showBanner("Could not save preferences: \(error.localizedDescription)", isError: true); return
        }
        if preferences.clubId != previousClubId {
            invalidateLoads()
            snapshot = store.loadSnapshot(clubId: preferences.clubId)
            errorMessage = nil; clearLateConfirm()
            Task { await load(forceRefresh: false) }
        }
        onStateChanged?()
    }

    /// Ignores errors (including 401) from a session that is no longer the signed-in one. A request refused because the
    /// Keychain account changed reloads that account instead of reporting a failure.
    private func handleBookingError(_ error: Error, for session: MemberSession) {
        guard isShown(session) else { return }
        if (error as? BookingClientError) == .sessionSuperseded {
            reloadLocalState(); showBanner(error.localizedDescription, isError: false); return
        }
        let expiry = BookingClientError.isUnauthorized(error) ? expireLocally(session) : nil
        showBanner([error.localizedDescription, expiry?.summary].compactMap { $0 }.joined(separator: " "), isError: true)
    }

    /// Applies an expiry of `session` (running it unless `outcome` already reports it): `.cleared` signs the UI out and
    /// notifies other surfaces, `.superseded` reloads the newer account, and `.failed` keeps the still-stored session
    /// visible with unknown bookings. The caller's banner carries `summary`, which names any cache error and Keychain
    /// warning of every outcome.
    @discardableResult
    private func expireLocally(_ session: MemberSession, outcome: SessionExpiryOutcome? = nil) -> SessionExpiryOutcome {
        let expiry = outcome ?? store.expireSession(for: session, keychain: keychain)
        switch expiry {
        case .cleared:
            isAccountOpen = true
            showSignedOut()
        case .superseded:
            reloadLocalState()
        case .failed:
            bookings = nil; clearLateConfirm()
            bookingsGeneration &+= 1
            // The rejected token's cached bookings were invalidated on disk despite the failed delete: refresh the widget.
            if expiry.didMutateDisk { onStateChanged?() }
        }
        return expiry
    }

    /// Whether `session` is the account this menu shows (token and owner: a replaced owner reusing a token is another account).
    private func isShown(_ session: MemberSession) -> Bool { memberSession?.token == session.token && memberSession?.ownerKey == session.ownerKey }

    private func clearLateConfirm() { confirmLateCancelId = nil; confirmLateCancelOwnerKey = nil; confirmLateCancelEntries = nil }

    /// `--self-test-mainactor` check: `model` uses the throwaway store folder and a `club.tertia.macos.selftest.*`
    /// Keychain service, never the user's real ones.
    public static func verifySelfTestIsolation(model: ScheduleViewModel, expectedStoreDirectory: URL) -> Bool {
        model.store.primaryDirectoryURL.standardizedFileURL == expectedStoreDirectory.standardizedFileURL
            && model.keychain.service.hasPrefix("club.tertia.macos.selftest.") && model.keychain.service != KeychainStore().service
    }

    private func showBanner(_ message: String, isError: Bool) { bannerMessage = message; bannerIsError = isError }

    /// `message` followed by every Keychain warning (never hidden by another error); any warning makes it an error banner.
    private func showBanner(_ message: String, warnings: [KeychainError], isError: Bool) {
        showBanner(([message] + warnings.map(\.localizedDescription)).joined(separator: " "), isError: isError || !warnings.isEmpty)
    }

    private func showMirrorWarning(_ error: Error) {
        showBanner("Saved, but updating the widget copy failed: \(error.localizedDescription)", isError: true)
    }

    private func persist(_ action: String, _ body: () throws -> Void) {
        do { try body() } catch { showBanner("Could not \(action): \(error.localizedDescription)", isError: true) }
    }

    /// Realigns the saved club to the account in the Keychain under the store lock (`alignPreferencesToCurrentAccount`:
    /// a member's timetable clubs, or the 17 public clubs when signed out), so it never overwrites a newer valid CLI
    /// choice, and recomputes the no-clubs error. Entering the no-clubs state or changing club discards in-flight
    /// loads. Returns whether the timetable must be loaded again (club changed, or the account left the no-clubs state).
    @discardableResult
    private func applyClubAlignment() -> Bool {
        alignmentSaveError = nil; alignmentMirrorError = nil
        let aligned: (preferences: TertiaPreferences, alignment: ClubAlignment, mirrorError: Error?)
        do {
            let read = try store.alignPreferencesToCurrentAccount(keychain: keychain)
            // Another process switched accounts in between: the next reload aligns for that account.
            guard (read.session?.token, read.session?.ownerKey) == (memberSession?.token, memberSession?.ownerKey) else { return false }
            // The same locked read's catalog: the 17 public clubs when signed out, the public catalog when signed in.
            if read.session == nil { signedOutCatalog = read.catalog } else { clubCatalog = read.catalog }
            aligned = (read.preferences, read.alignment, read.mirrorError)
        } catch {
            alignmentSaveError = error
            showBanner("Could not save preferences: \(error.localizedDescription)", isError: true); return false
        }
        return adoptAlignment(aligned)
    }

    /// Adopts a realigned club read for the shown account: preferences, the no-clubs error, and (when the club changed)
    /// that club's snapshot, discarding in-flight loads. Returns whether the timetable must be loaded again.
    @discardableResult
    private func adoptAlignment(_ aligned: (preferences: TertiaPreferences, alignment: ClubAlignment, mirrorError: Error?)) -> Bool {
        let wasNoneEntitled = errorMessage == Self.noClubsMessage
        let previousClubId = preferences.clubId
        preferences = aligned.preferences
        if let mirrorError = aligned.mirrorError { alignmentMirrorError = mirrorError; showMirrorWarning(mirrorError) }
        if aligned.alignment == .noneEntitled {
            if snapshot != nil || !wasNoneEntitled { invalidateLoads() }
            snapshot = nil; errorMessage = Self.noClubsMessage
            return false
        }
        if wasNoneEntitled { errorMessage = nil }
        guard preferences.clubId != previousClubId else { return wasNoneEntitled }
        invalidateLoads()
        snapshot = store.loadSnapshot(clubId: preferences.clubId)
        return true
    }
}

/// A lock-guarded string shared with the `@Sendable` authorization that runs under `.mutation.lock`.
private final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(_ value: String) { stored = value }
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

public struct MenuBarScheduleView: View {
    @ObservedObject public var model: ScheduleViewModel
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.openURL) private var openURL
    public let onQuit: (() -> Void)?
    public let staticPreview: Bool
    public let previewNow: Date?

    /// `staticPreview` only freezes the clock at `previewNow` and skips appearance and notification side effects; every
    /// control is the shipped one (see `controlSummary`).
    public init(model: ScheduleViewModel, onQuit: (() -> Void)? = nil, staticPreview: Bool = false, previewNow: Date? = nil) {
        self.model = model; self.onQuit = onQuit; self.staticPreview = staticPreview; self.previewNow = previewNow
    }

    /// The controls this menu draws: date pills in the strip, rows in the club picker, and whether the header has Quit.
    public var controlSummary: (datePills: Int, clubRows: Int, hasQuit: Bool) {
        (LondonCalendar.dateStrip(days: Self.dateStripDays, now: previewNow ?? Date()).count, model.availableClubs.count, onQuit != nil)
    }

    /// A live menu redraws itself at every local badge or visibility boundary (no timers, no network) and, once London
    /// midnight passes while it is open, moves to today and reloads the public timetable (zero private calls); a static
    /// preview renders once at `previewNow`.
    public var body: some View {
        // One read of the account's stored timetables per render pass, shared by the redraw boundaries, the list, the
        // empty state, and every card.
        let index = model.entitledTimetableIndex()
        return Group {
            if staticPreview {
                content(now: previewNow ?? Date(), index: index)
            } else {
                TimelineView(.explicit(model.upcomingBoundaryDates(index: index))) { context in
                    content(now: context.date, index: index)
                        .task(id: LondonCalendar.londonTodayIso(now: context.date)) { await model.rolloverMidnightIfNeeded(now: context.date) }
                }
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(SharedStateStore.stateChangedNotification)).receive(on: RunLoop.main)) { _ in
            if !staticPreview { model.syncFromDisk() }
        }
        .onAppear {
            // Every appearance reloads disk state, then runs one cache-aware public load (zero private API calls).
            guard !staticPreview else { return }
            model.handleAppear()
            Task { await model.load(forceRefresh: false) }
        }
    }

    private func content(now: Date, index: SharedStateStore.EntitledTimetableIndex?) -> some View {
        let activeScheme = model.themeOverride ?? systemScheme
        let palette = TertiaPalette.resolve(activeScheme)
        let items = model.filteredClasses(index: index, now: now)

        return ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                headerBar(palette: palette, activeScheme: activeScheme)
                Divider().overlay(palette.border)
                if model.isAccountOpen { accountSection(palette: palette); Divider().overlay(palette.border) }
                if let banner = model.bannerMessage { bannerBar(text: banner, palette: palette); Divider().overlay(palette.border) }
                controlsSection(palette: palette, now: now)
                Divider().overlay(palette.border)
                scheduleBody(items: items, index: index, palette: palette, now: now)
                Divider().overlay(palette.border)
                footerBar(count: items.count, palette: palette, now: now)
            }

            if model.isClubMenuOpen {
                Color.black.opacity(0.001).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { model.isClubMenuOpen = false } }

                ClubDropdownPanel(
                    clubs: model.availableClubs,
                    selectedClubId: model.preferences.clubId,
                    palette: palette,
                    frozen: staticPreview,
                    onSelect: { club in withAnimation(.easeOut(duration: 0.12)) { model.selectClub(club) } }
                )
                .padding(.top, model.isAccountOpen ? 186 : 88)
                .padding(.trailing, 14)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            }
        }
        .frame(width: 392, height: 560)
        .tertiaSurface(fill: palette.canvas, border: staticPreview ? palette.border : .clear, radius: staticPreview ? TertiaMetrics.containerRadius : 0)
        .environment(\.colorScheme, activeScheme)
    }

    private func headerBar(palette: TertiaPalette, activeScheme: ColorScheme) -> some View {
        HStack {
            TertiaWordmarkView(palette: palette, compact: false)
            Spacer()
            HStack(spacing: 4) {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { model.isAccountOpen.toggle(); model.isClubMenuOpen = false }
                } label: {
                    HStack(spacing: 5) {
                        if model.memberSession != nil { Circle().fill(palette.openStatus).frame(width: 6, height: 6) }
                        Text(model.memberSession?.firstName ?? "Sign in").font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(model.isAccountOpen || model.memberSession != nil ? palette.ink : palette.muted)
                    .padding(.horizontal, 8).frame(height: 26)
                    .tertiaSurface(fill: palette.pillSurface, border: model.isAccountOpen ? palette.border : .clear, radius: 7)
                }
                .buttonStyle(.plain).help("Member account")

                iconButton("arrow.clockwise", help: "Refresh schedule and bookings", palette: palette) { Task { await model.load(forceRefresh: true) } }
                    .disabled(model.isLoading).opacity(model.isLoading ? 0.45 : 1.0)
                iconButton(activeScheme == .dark ? "sun.max" : "moon", help: "Switch appearance", palette: palette) { model.toggleTheme() }
                iconButton("arrow.up.right.square", help: "Open on thirdspace.london", palette: palette) {
                    if let url = URL(string: "https://www.thirdspace.london/timetable/?location_id=\(model.preferences.clubId)") { openURL(url) }
                }
                if let onQuit { iconButton("power", help: "Quit Tertia", palette: palette, action: onQuit) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func iconButton(_ icon: String, help: String, palette: TertiaPalette, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11.5, weight: .medium)).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.pillSurface))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain).foregroundStyle(palette.muted).help(help)
    }

    @ViewBuilder
    private func accountSection(palette: TertiaPalette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = model.memberSession {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.ink)
                        Text(session.email).font(.system(size: 10.5)).foregroundStyle(palette.muted)
                    }
                    Spacer()
                    Button("Sign out") { model.signOut() }
                        .disabled(model.isAuthBusy || model.busyClassId != nil)
                        .buttonStyle(.plain).font(.system(size: 10.5, weight: .medium)).foregroundStyle(palette.ink)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .tertiaSurface(fill: palette.card, border: palette.border, radius: TertiaMetrics.pillRadius)
                }
            } else {
                HStack(spacing: 6) {
                    TextField("Third Space email", text: $model.emailInput)
                        .textFieldStyle(.plain).focusEffectDisabled().font(.system(size: 11.5)).foregroundStyle(palette.ink)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .tertiaSurface(fill: palette.card, border: palette.border, radius: TertiaMetrics.pillRadius)

                    SecureField("Password", text: $model.passwordInput)
                        .textFieldStyle(.plain).focusEffectDisabled().font(.system(size: 11.5)).foregroundStyle(palette.ink)
                        .onSubmit { Task { await model.signIn() } }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .tertiaSurface(fill: palette.card, border: palette.border, radius: TertiaMetrics.pillRadius)
                }
                HStack {
                    Text("Keychain only · Syncs on login, refresh & book").font(.system(size: 9.5)).foregroundStyle(palette.faint)
                    Spacer()
                    Button { Task { await model.signIn() } } label: {
                        Text(model.isAuthBusy ? "Signing in..." : "Sign In")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.pillSelectedText)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.pillSelected))
                    }
                    .buttonStyle(.plain).disabled(model.isAuthBusy || model.busyClassId != nil)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9).background(palette.pillSurface)
    }

    private func bannerBar(text: String, palette: TertiaPalette) -> some View {
        let accent = model.bannerIsError || model.confirmLateCancelId.map(model.isConfirmingLateCancel) == true ? palette.warningStatus : palette.openStatus
        return HStack(alignment: .top, spacing: 6) {
            Circle().fill(accent).frame(width: 6, height: 6).padding(.top, 4)
            Text(text).font(.system(size: 10.5)).foregroundStyle(palette.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.bannerMessage = nil; model.confirmLateCancelId = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.faint).padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 6).background(accent.opacity(0.08))
    }

    private func controlsSection(palette: TertiaPalette, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Timetable").font(.system(size: 17, weight: .regular, design: .serif)).foregroundStyle(palette.ink)
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.14)) { model.isAccountOpen = false; model.isClubMenuOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.preferences.clubName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(model.isClubMenuOpen ? 180 : 0)).foregroundStyle(palette.muted)
                    }
                    .foregroundStyle(palette.ink).padding(.horizontal, 10).padding(.vertical, 5)
                    .tertiaSurface(fill: palette.pillSurface, border: model.isClubMenuOpen ? palette.ink.opacity(0.35) : palette.border, radius: TertiaMetrics.pillRadius)
                    .contentShape(RoundedRectangle(cornerRadius: TertiaMetrics.pillRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            PreviewableScroll(axis: .horizontal, frozen: staticPreview) {
                HStack(spacing: 6) {
                    ForEach(LondonCalendar.dateStrip(days: Self.dateStripDays, now: now)) { day in
                        Button { model.selectDate(day.iso) } label: {
                            dayPill(day: day, selected: day.iso == model.effectiveSelectedDate(now: now), palette: palette)
                        }.buttonStyle(.plain).disabled(model.isDaySwitchLocked)
                    }
                }
            }
            .frame(height: 42)

            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(SchedulePeriod.allCases, id: \.self) { period in
                        let active = model.preferences.period == period
                        Button { model.selectPeriod(period) } label: {
                            Text(period.shortLabel).font(.system(size: 10.5, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(active ? palette.pillSelectedText : palette.muted)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? palette.pillSelected : .clear))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(3).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.pillSurface))

                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(palette.faint)
                    if staticPreview { // a frozen field: the same text and font, without an editor or a blinking cursor
                        Text(model.preferences.searchQuery.isEmpty ? "Class or coach" : model.preferences.searchQuery).font(.system(size: 11.5))
                            .foregroundStyle(model.preferences.searchQuery.isEmpty ? palette.faint : palette.ink).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Class or coach", text: Binding(get: { model.preferences.searchQuery }, set: { model.updateSearch($0) }))
                            .textFieldStyle(.plain).focusEffectDisabled().font(.system(size: 11.5)).foregroundStyle(palette.ink)
                    }
                    if !model.preferences.searchQuery.isEmpty {
                        Button { model.updateSearch("") } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)).foregroundStyle(palette.faint) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5).tertiaSurface(fill: palette.pillSurface, border: palette.border, radius: 9)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Days in the date strip, shipped menu and README previews alike.
    public static let dateStripDays = 10

    private func dayPill(day: DateEntry, selected: Bool, palette: TertiaPalette) -> some View {
        VStack(spacing: 1) {
            Text(day.weekday).font(.system(size: 8.5, weight: .medium, design: .monospaced)).tracking(0.8)
            Text(day.dayNumber).font(.system(size: 12, weight: .semibold, design: .monospaced)).monospacedDigit()
        }
        .frame(width: 44, height: 42)
        .foregroundStyle(selected ? palette.pillSelectedText : palette.muted)
        .tertiaSurface(fill: selected ? palette.pillSelected : palette.pillSurface, border: selected ? palette.pillSelected : palette.border, radius: 9)
    }

    @ViewBuilder
    private func scheduleBody(items: [ClassSession], index: SharedStateStore.EntitledTimetableIndex?, palette: TertiaPalette, now: Date) -> some View {
        if model.isLoading && items.isEmpty {
            VStack(spacing: 8) {
                Spacer(); ProgressView()
                Text("Loading public timetable...").font(.system(size: 11.5)).foregroundStyle(palette.muted)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, items.isEmpty {
            emptyState(title: "Schedule unavailable", detail: error, button: "Retry", palette: palette) { await model.retryPublicSchedule() }
        } else if items.isEmpty && !model.isShownDayCached(now: now) {
            emptyState(title: model.emptyScheduleMessage(index: index, now: now), detail: nil, button: "Load Schedule", palette: palette) { await model.load(forceRefresh: false) }
        } else if items.isEmpty {
            VStack { Spacer(); Text(model.emptyScheduleMessage(index: index, now: now)).font(.system(size: 13, design: .serif)).foregroundStyle(palette.muted); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PreviewableScroll(axis: .vertical, frozen: staticPreview) {
                LazyVStack(spacing: 6) { ForEach(items) { classCard(session: $0, index: index, palette: palette, now: now) } }
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
    }

    private func emptyState(title: String, detail: String?, button: String, palette: TertiaPalette, action: @escaping @MainActor () async -> Void) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(title).font(.system(size: 14, design: .serif)).foregroundStyle(palette.ink)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(palette.muted).multilineTextAlignment(.center) }
            Button { Task { await action() } } label: {
                Text(button).font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(1.0)
                    .foregroundStyle(palette.ink).padding(.horizontal, 14).padding(.vertical, 6)
                    .tertiaSurface(fill: palette.pillSurface, border: palette.border, radius: TertiaMetrics.pillRadius)
            }.buttonStyle(.plain)
            Spacer()
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Actions need a session, known bookings, and an entitled club, and lock while another class or the account is busy.
    /// The button captures what it shows (book, cancel, or the late confirmation), the session token, and the club, so a
    /// click is refused if any of them changed. Cancel eligibility follows `BookingAuthorization.canCancel`, the same
    /// rule the action runs.
    private func classCard(session: ClassSession, index: SharedStateStore.EntitledTimetableIndex?, palette: TertiaPalette, now: Date) -> some View {
        let inputs = model.cardInputs(for: session, index: index, now: now)
        let action = model.classAction(for: session, index: index, inputs: inputs, now: now)
        return CompactClassCard(
            session: session, palette: palette, now: now, dense: false,
            isBooked: inputs.isBooked, isBusy: model.busyClassId == session.id,
            confirmingLateCancel: model.isConfirmingLateCancel(session.id), canCancelBooked: inputs.canCancelBooked,
            onAction: action.map { action in { () -> Void in _ = Task { await action() } } }
        )
    }

    private func footerBar(count: Int, palette: TertiaPalette, now: Date) -> some View {
        let statusText = model.footerStatusText(count: count, now: now)
        return HStack {
            Text(model.preferences.clubName.uppercased()).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(palette.faint)
            Spacer()
            Text(statusText).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.1).foregroundStyle(palette.faint)
        }
        .padding(.horizontal, 14).padding(.vertical, 7).background(palette.pillSurface)
    }
}

/// A scroll view in the live menu. A static preview (`ImageRenderer` cannot draw an AppKit scroll view) draws the same
/// content at scroll offset 0, clipped to the same viewport, so README screenshots show the shipped geometry.
struct PreviewableScroll<Content: View>: View {
    let axis: Axis.Set
    let frozen: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if frozen {
            Color.clear.overlay(alignment: axis == .horizontal ? .leading : .top) {
                content.fixedSize(horizontal: axis == .horizontal, vertical: axis == .vertical)
            }
            .clipped()
        } else {
            ScrollView(axis, showsIndicators: false) { content }
        }
    }
}

struct ClubDropdownPanel: View {
    let clubs: [Club]
    let selectedClubId: Int
    let palette: TertiaPalette
    var frozen = false
    let onSelect: (Club) -> Void

    var body: some View {
        let content = VStack(spacing: 2) {
            ForEach(clubs) { club in
                let isSelected = club.id == selectedClubId
                Button { onSelect(club) } label: {
                    HStack(spacing: 8) {
                        Text(club.name).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.ink)
                        } else if !club.shortCode.isEmpty {
                            Text(club.shortCode).font(.system(size: 8.5, weight: .medium, design: .monospaced)).tracking(0.8).foregroundStyle(palette.faint)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? palette.pillSurface : .clear))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.padding(6)

        PreviewableScroll(axis: .vertical, frozen: frozen) { content }.frame(width: 224, height: Self.height(clubCount: clubs.count))
        .tertiaSurface(fill: palette.card, border: palette.border, radius: TertiaMetrics.cardRadius)
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 6)
    }

    /// The panel shows every club, scrolling past 9 rows.
    static func height(clubCount: Int) -> CGFloat { min(CGFloat(clubCount) * 30 + 12, 276) }
}
