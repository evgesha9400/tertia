import SwiftUI
import TertiaCore
import TertiaUI
import WidgetKit

struct TertiaScheduleEntry: TimelineEntry {
    let date: Date
    /// `nil` when no timetable for the selected club is available; never sample data in a live widget.
    let snapshot: TimetableSnapshot?
    let preferences: TertiaPreferences
    let bookedIds: Set<Int>
    /// The mirror's row tokens; each view badges a booked ID only on the row its token names.
    var rowTokens: Set<String>?
}

private struct CompletionBox<Value>: @unchecked Sendable { let handler: (Value) -> Void }

struct TertiaTimelineProvider: TimelineProvider {
    /// Gallery preview and placeholder: sample classes at the fixed preview clock (`widgetGalleryPreview`), never `Date()`,
    /// so the gallery is never empty late in the evening.
    func placeholder(in context: Context) -> TertiaScheduleEntry {
        let preview = widgetGalleryPreview()
        return TertiaScheduleEntry(date: preview.date, snapshot: preview.snapshot, preferences: TertiaPreferences(), bookedIds: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (TertiaScheduleEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        let state = loadWidgetState(store: SharedStateStore())
        completion(TertiaScheduleEntry(date: Date(), snapshot: state.snapshot, preferences: state.preferences, bookedIds: state.bookedIds, rowTokens: state.rowTokens))
    }

    /// Preferences, snapshot, and booked IDs are read together after the public fetch, so a club or account change
    /// during the request never mixes states.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TertiaScheduleEntry>) -> Void) {
        let box = CompletionBox(handler: completion)
        Task {
            let store = SharedStateStore()
            let now = Date()
            let state = await refreshWidgetState(store: store, client: PublicTimetableClient(store: store), now: now)
            let entries = widgetTimelineDates(snapshot: state.snapshot, preferences: state.preferences, now: now).map {
                TertiaScheduleEntry(date: $0, snapshot: state.snapshot, preferences: state.preferences, bookedIds: state.bookedIds, rowTokens: state.rowTokens)
            }
            box.handler(Timeline(entries: entries, policy: .after(now.addingTimeInterval(45 * 60))))
        }
    }
}

struct TertiaWidgetEntryView: View {
    let entry: TertiaScheduleEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall: TertiaSmallWidgetView(snapshot: entry.snapshot, preferences: entry.preferences, bookedIds: entry.bookedIds, rowTokens: entry.rowTokens, now: entry.date)
        case .systemLarge: TertiaLargeWidgetView(snapshot: entry.snapshot, preferences: entry.preferences, bookedIds: entry.bookedIds, rowTokens: entry.rowTokens, now: entry.date)
        default: TertiaMediumWidgetView(snapshot: entry.snapshot, preferences: entry.preferences, bookedIds: entry.bookedIds, rowTokens: entry.rowTokens, now: entry.date)
        }
    }
}

struct TertiaScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TertiaScheduleWidget", provider: TertiaTimelineProvider()) { entry in
            TertiaWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) { TertiaWidgetBackground() }
                .widgetURL(URL(string: "tertia://open"))
        }
        .configurationDisplayName("Tertia Timetable")
        .description("Compact Third Space class schedule synced from the public timetable.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

private struct TertiaWidgetBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var body: some View { TertiaPalette.resolve(colorScheme).canvas }
}

@main
struct TertiaWidgetBundle: WidgetBundle {
    var body: some Widget { TertiaScheduleWidget() }
}
