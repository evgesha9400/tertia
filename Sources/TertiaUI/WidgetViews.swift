import SwiftUI
import TertiaCore

/// Today's classes that have not started (a class leaves at its exact start); shared by the widget views and the
/// timeline provider.
public func widgetUpcomingSessions(snapshot: TimetableSnapshot?, preferences: TertiaPreferences, now: Date) -> [ClassSession] {
    guard let snapshot else { return [] }
    let todayIso = LondonCalendar.londonTodayIso(now: now)
    return LondonCalendar.filterSessions(snapshot.classes(for: todayIso), period: preferences.period, search: preferences.searchQuery, selectedDate: todayIso, now: now, includePastGraceMinutes: 0)
}

/// Timeline entry dates: `now`, each distinct class start in `(now, now + 45 min]` (the row leaves exactly then) on
/// every London date that window touches (so a 00:10 class cached for tomorrow counts at 23:40), and the next London
/// midnight when it falls inside the window. With a period or search filter active, the last unfiltered start of each
/// of those dates in that window is an entry too: there "No classes match filter" turns into the club's "no more
/// classes" wording.
public func widgetTimelineDates(snapshot: TimetableSnapshot?, preferences: TertiaPreferences, now: Date) -> [Date] {
    let horizon = now.addingTimeInterval(45 * 60)
    let todayIso = LondonCalendar.londonTodayIso(now: now)
    let midnight = LondonCalendar.nextMidnight(after: now).flatMap { $0 <= horizon ? $0 : nil }
    let days = [todayIso] + (midnight == nil ? [] : [LondonCalendar.addDays(to: todayIso, days: 1)].compactMap { $0 })
    let hasFilter = preferences.period != .all || !preferences.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let starts = snapshot.map { snap in
        days.flatMap { day -> [Date] in
            let dayStart = LondonCalendar.londonWallDate(dateIso: day, hhmm: "00:00") ?? now
            func dayStarts(_ period: SchedulePeriod, _ search: String) -> [Date] {
                LondonCalendar.filteredSessionStarts(snap.classes(for: day), period: period, search: search, selectedDate: day,
                                                     now: max(now, dayStart), includePastGraceMinutes: 0).compactMap(\.start)
            }
            return dayStarts(preferences.period, preferences.searchQuery) + (hasFilter ? dayStarts(.all, "").max().map { [$0] } ?? [] : [])
        }
    } ?? []
    return [now] + Set(starts + [midnight].compactMap { $0 }).filter { $0 > now && $0 <= horizon }.sorted()
}

/// Widget gallery and placeholder entry: the sample timetable at its fixed 06:00 London preview clock
/// (`SampleData.previewScene`), so the gallery shows upcoming classes at any time of day. Live entries never use it.
public func widgetGalleryPreview(now: Date = Date()) -> (date: Date, snapshot: TimetableSnapshot) {
    let scene = SampleData.previewScene(live: nil, now: now)
    return (scene.now, scene.snapshot)
}

/// Preferences, the selected club's snapshot, the widget's booked IDs, and the mirror's row tokens
/// (`SharedStateStore.widgetRowToken`; `nil` for a legacy mirror), read together so they describe one state.
public struct WidgetState: Sendable {
    public let preferences: TertiaPreferences
    public let snapshot: TimetableSnapshot?
    public let bookedIds: Set<Int>
    public let rowTokens: Set<String>?
}

/// Reads the current state from `store` at `now` (a snapshot of another club is never returned).
public func loadWidgetState(store: SharedStateStore, now: Date = Date()) -> WidgetState {
    let state = store.readConsistentWidgetState(now: now)
    return WidgetState(preferences: state.preferences, snapshot: state.snapshot, bookedIds: state.bookedIds, rowTokens: state.rowTokens)
}

/// Warms today's public timetable for the saved club (cache-aware) and, when the next London midnight falls inside the
/// 45-minute timeline window, tomorrow's too (unless already cached), then reads the state again after the requests,
/// so a club or account change made during a fetch never mixes old and new values in one entry. Public pages only.
public func refreshWidgetState(store: SharedStateStore, client: PublicTimetableClient, now: Date = Date()) async -> WidgetState {
    let clubId = store.loadPreferences().clubId, todayIso = LondonCalendar.londonTodayIso(now: now)
    let snap = try? await client.fetchSchedule(clubId: clubId, date: todayIso, forceRefresh: false)
    if let midnight = LondonCalendar.nextMidnight(after: now), midnight <= now.addingTimeInterval(45 * 60),
       let tomorrowIso = LondonCalendar.addDays(to: todayIso, days: 1), snap?.hasCachedDay(tomorrowIso) != true {
        _ = try? await client.fetchSchedule(clubId: clubId, date: tomorrowIso, forceRefresh: false)
    }
    return loadWidgetState(store: store, now: now)
}

/// Empty-state text shared by every widget size: "Timetable unavailable" when today is not cached (offline with only
/// yesterday, or no snapshot); "No classes match filter" when a period or search filter hides classes that are still
/// to come today; otherwise the size's own `clubEmpty` wording.
public func widgetEmptyText(snapshot: TimetableSnapshot?, preferences: TertiaPreferences, now: Date, clubEmpty: String) -> String {
    let todayIso = LondonCalendar.londonTodayIso(now: now)
    guard let snapshot, snapshot.hasCachedDay(todayIso) else { return "Timetable unavailable" }
    let filtered = preferences.period != .all || !preferences.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let upcoming = LondonCalendar.filterSessions(snapshot.classes(for: todayIso), period: .all, search: "", selectedDate: todayIso, now: now, includePastGraceMinutes: 0)
    return filtered && !upcoming.isEmpty ? "No classes match filter" : clubEmpty
}

/// Large widget footer: today's sync time, or "NOT SYNCED" when today was never fetched.
public func widgetSyncLabel(snapshot: TimetableSnapshot?, now: Date) -> String {
    snapshot?.syncedAt(for: LondonCalendar.londonTodayIso(now: now)).map { "SYNCED \(LondonCalendar.formatSyncTime($0))" } ?? "NOT SYNCED"
}

/// The booked IDs a widget view may badge: an ID that is ambiguous inside the shown club's snapshot never shows `BOOKED`,
/// whoever built the view (`loadWidgetState` also drops IDs that appear in another club's stored snapshot). With row
/// tokens (`WidgetState.rowTokens`), an ID is kept only when its one row's token names that row's date and the shown
/// club (or the row's own club), so every timeline entry, including one past midnight, badges only the booked row.
func widgetBadgeIds(_ bookedIds: Set<Int>, rowTokens: Set<String>?, snapshot: TimetableSnapshot?, preferences: TertiaPreferences) -> Set<Int> {
    SharedStateStore.unambiguousWidgetBookedIds(bookedIds, selectedClubId: preferences.clubId, selectedSnapshot: snapshot, otherSnapshots: []).filter { id in
        guard let rowTokens else { return true }
        guard case .unique(let row)? = snapshot?.lookupSession(id: id) else { return false }
        return [preferences.clubName, row.clubName].contains { rowTokens.contains(SharedStateStore.widgetRowToken(classId: id, clubName: $0, dateIso: row.date)) }
    }
}

public struct TertiaSmallWidgetView: View {
    public let snapshot: TimetableSnapshot?
    public let preferences: TertiaPreferences
    public let bookedIds: Set<Int>
    public let now: Date
    @Environment(\.colorScheme) private var colorScheme

    public init(snapshot: TimetableSnapshot?, preferences: TertiaPreferences, bookedIds: Set<Int> = [], rowTokens: Set<String>? = nil, now: Date = Date()) {
        self.snapshot = snapshot; self.preferences = preferences; self.now = now
        self.bookedIds = widgetBadgeIds(bookedIds, rowTokens: rowTokens, snapshot: snapshot, preferences: preferences)
    }

    public var body: some View {
        let palette = TertiaPalette.resolve(colorScheme)
        let sessions = widgetUpcomingSessions(snapshot: snapshot, preferences: preferences, now: now)
        let next = sessions.first

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TertiaBrandMark(size: 14, color: palette.ink)
                Spacer()
                Text(preferences.clubShortCode.isEmpty ? "LONDON" : preferences.clubShortCode)
                    .font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(palette.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(palette.pillSurface))
            }
            Spacer(minLength: 0)
            if let next {
                VStack(alignment: .leading, spacing: 4) {
                    Text(next.startTime).font(.system(size: 18, weight: .medium, design: .monospaced)).monospacedDigit().foregroundStyle(palette.ink)
                    Text(next.title).font(.system(size: 14, weight: .regular, design: .serif)).foregroundStyle(palette.ink).lineLimit(2)
                    Text(next.trainer.isEmpty ? "Instructor TBA" : next.trainer).font(.system(size: 10.5)).foregroundStyle(palette.muted).lineLimit(1)
                }
            } else {
                Text(widgetEmptyText(snapshot: snapshot, preferences: preferences, now: now, clubEmpty: "No more classes today")).font(.system(size: 13, weight: .regular, design: .serif)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 0)
            HStack {
                if let next {
                    if bookedIds.contains(next.id) {
                        let colors = CompactClassCard.Badge.booked.chipColors(palette)
                        StatusChip(label: CompactClassCard.Badge.booked.label, fg: colors.fg, bg: colors.bg, border: colors.border)
                    } else {
                        StatusPill(status: LondonCalendar.bookingWindowStatus(for: next, now: now), palette: palette)
                    }
                }
                Spacer()
                if sessions.count > 1 { Text("+\(sessions.count - 1)").font(.system(size: 9.5, weight: .medium, design: .monospaced)).foregroundStyle(palette.faint) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct TertiaMediumWidgetView: View {
    public let snapshot: TimetableSnapshot?
    public let preferences: TertiaPreferences
    public let bookedIds: Set<Int>
    public let now: Date
    @Environment(\.colorScheme) private var colorScheme

    public init(snapshot: TimetableSnapshot?, preferences: TertiaPreferences, bookedIds: Set<Int> = [], rowTokens: Set<String>? = nil, now: Date = Date()) {
        self.snapshot = snapshot; self.preferences = preferences; self.now = now
        self.bookedIds = widgetBadgeIds(bookedIds, rowTokens: rowTokens, snapshot: snapshot, preferences: preferences)
    }

    public var body: some View {
        let sessions = Array(widgetUpcomingSessions(snapshot: snapshot, preferences: preferences, now: now).prefix(3))
        WidgetListShell(
            clubName: preferences.clubName, sessions: sessions,
            bookedIds: bookedIds, palette: TertiaPalette.resolve(colorScheme), now: now, compact: true,
            emptyText: sessions.isEmpty ? widgetEmptyText(snapshot: snapshot, preferences: preferences, now: now, clubEmpty: "No upcoming classes at \(preferences.clubName) today.") : "",
            footer: nil
        )
    }
}

public struct TertiaLargeWidgetView: View {
    public let snapshot: TimetableSnapshot?
    public let preferences: TertiaPreferences
    public let bookedIds: Set<Int>
    public let now: Date
    @Environment(\.colorScheme) private var colorScheme

    public init(snapshot: TimetableSnapshot?, preferences: TertiaPreferences, bookedIds: Set<Int> = [], rowTokens: Set<String>? = nil, now: Date = Date()) {
        self.snapshot = snapshot; self.preferences = preferences; self.now = now
        self.bookedIds = widgetBadgeIds(bookedIds, rowTokens: rowTokens, snapshot: snapshot, preferences: preferences)
    }

    public var body: some View {
        let sessions = Array(widgetUpcomingSessions(snapshot: snapshot, preferences: preferences, now: now).prefix(5))
        WidgetListShell(
            clubName: preferences.clubName, sessions: sessions,
            bookedIds: bookedIds, palette: TertiaPalette.resolve(colorScheme), now: now, compact: false,
            emptyText: sessions.isEmpty ? widgetEmptyText(snapshot: snapshot, preferences: preferences, now: now, clubEmpty: "No more classes today.") : "",
            footer: ("SCHEDULE · \(preferences.period.label.uppercased())", widgetSyncLabel(snapshot: snapshot, now: now))
        )
    }
}

private struct WidgetListShell: View {
    let clubName: String
    let sessions: [ClassSession]
    let bookedIds: Set<Int>
    let palette: TertiaPalette
    let now: Date
    let compact: Bool
    let emptyText: String
    let footer: (left: String, right: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .center) {
                TertiaWordmarkView(palette: palette, compact: compact)
                Spacer()
                Text(clubName.uppercased()).font(.system(size: compact ? 9 : 9.5, weight: .medium, design: .monospaced))
                    .tracking(compact ? 1.1 : 1.2).foregroundStyle(palette.ink)
                    .padding(.horizontal, compact ? 8 : 9).padding(.vertical, compact ? 3 : 4)
                    .background(Capsule().fill(palette.pillSurface)).lineLimit(1)
            }
            if sessions.isEmpty {
                Spacer()
                Text(emptyText).font(.system(size: compact ? 12 : 13, design: .serif)).foregroundStyle(palette.muted)
                Spacer()
            } else {
                VStack(spacing: compact ? 5 : 6) {
                    ForEach(sessions) { CompactClassCard(session: $0, palette: palette, now: now, dense: compact, isBooked: bookedIds.contains($0.id)) }
                }
            }
            if let footer {
                Spacer(minLength: 0)
                HStack {
                    Text(footer.left).font(.system(size: 8.5, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(palette.faint)
                    Spacer()
                    Text(footer.right).font(.system(size: 8.5, weight: .medium, design: .monospaced)).tracking(1.2).foregroundStyle(palette.faint)
                }
            }
        }
        .padding(compact ? 12 : 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

public struct WidgetPreviewWrapper<Content: View>: View {
    public let width, height: CGFloat
    public let scheme: ColorScheme
    public let content: Content

    public init(width: CGFloat, height: CGFloat, scheme: ColorScheme, @ViewBuilder content: () -> Content) {
        self.width = width; self.height = height; self.scheme = scheme; self.content = content()
    }

    public var body: some View {
        content.frame(width: width, height: height)
            .tertiaSurface(fill: TertiaPalette.resolve(scheme).canvas, border: TertiaPalette.resolve(scheme).border, radius: 22)
            .environment(\.colorScheme, scheme)
    }
}
