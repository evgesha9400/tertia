import AppKit
import Darwin
import SwiftUI
import TertiaCLI
import TertiaCore
import TertiaUI
import WidgetKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// `--self-test-mainactor` binds the model to a temporary store and a throwaway Keychain service so the liveness
    /// probe never reads or writes the user's real session or `~/Library/Application Support/TertiaClub`.
    private let selfTestDirectory: URL?
    let model: ScheduleViewModel
    private var standaloneWindow: NSWindow?

    override init() {
        if CommandLine.arguments.contains("--self-test-mainactor") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tertia-selftest-\(UUID().uuidString)", isDirectory: true)
            let store = SharedStateStore(primaryDirectory: dir)
            selfTestDirectory = dir
            model = ScheduleViewModel(store: store, keychain: KeychainStore(service: "club.tertia.macos.selftest.\(UUID().uuidString)"))
        } else {
            selfTestDirectory = nil
            model = ScheduleViewModel(onStateChanged: { WidgetCenter.shared.reloadAllTimelines() })
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let selfTestDirectory {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000)
                let isolated = ScheduleViewModel.verifySelfTestIsolation(model: model, expectedStoreDirectory: selfTestDirectory)
                try? FileManager.default.removeItem(at: selfTestDirectory)
                print("MAINACTOR_ALIVE ISOLATED_STORE=\(isolated ? 1 : 0)")
                Foundation.exit(isolated ? 0 : 1)
            }
            return
        }
        if CommandLine.arguments.contains("--window") { DispatchQueue.main.async { self.openStandaloneWindow() } }
    }

    func application(_ application: NSApplication, open urls: [URL]) { openStandaloneWindow() }

    /// A hidden or new window reloads through the view's `.onAppear`; an already visible one reloads here.
    func openStandaloneWindow() {
        if standaloneWindow?.isVisible == true { model.syncFromDisk() }
        if standaloneWindow == nil {
            let win = NSWindow(contentViewController: NSHostingController(rootView: MenuBarScheduleView(model: model, onQuit: nil)))
            win.title = "Tertia Timetable"; win.setContentSize(NSSize(width: 392, height: 560))
            win.styleMask = [.titled, .closable]; win.isReleasedWhenClosed = false; win.center()
            standaloneWindow = win
        }
        standaloneWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TertiaMainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarScheduleView(model: appDelegate.model, onQuit: { NSApplication.shared.terminate(nil) })
        } label: {
            Image(nsImage: makeTertiaMenuBarImage(pointSize: 17)).accessibilityLabel("Tertia Timetable")
        }
        .menuBarExtraStyle(.window)
    }
}

@main
enum TertiaEntrypoint {
    @Sendable private static func notifyCLIStateChanged() {
        WidgetCenter.shared.reloadAllTimelines()
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(SharedStateStore.stateChangedNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }

    @MainActor
    static func main() {
        let argv0 = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "Tertia"
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        if rawArgs.first == "render-previews" {
            Darwin.alarm(25)
            Task { @MainActor in Foundation.exit(await renderPreviews(args: Array(rawArgs.dropFirst()))) }
            RunLoop.main.run()
        } else if argv0 == "tertia" || TertiaCLI.shouldHandle(firstArg: rawArgs.first) {
            Task.detached { Foundation.exit(await TertiaCLI.run(args: rawArgs, onStateChanged: notifyCLIStateChanged)) }
            dispatchMain()
        } else {
            if rawArgs.contains("--self-test-mainactor") { Darwin.alarm(5) }
            TertiaMainApp.main()
        }
    }

    /// Renders the 8 README PNGs from an isolated temporary store (removed on exit). `--offline` skips the public site;
    /// the clock and data follow `SampleData.previewScene`.
    @MainActor
    private static func renderPreviews(args: [String]) async -> Int32 {
        let usage = "usage: tertia render-previews [--out <dir>] [--offline]"
        let parsed: (values: [String: String], flags: Set<String>, positionals: [String])
        do {
            parsed = try TertiaCLI.parseOptions(args, valueFlags: ["--out"], boolFlags: ["--offline"])
            guard parsed.positionals.isEmpty else { throw CLIError.usage(usage) }
        } catch CLIError.helpRequested { print(usage); return 0 } catch { FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); return 1 }

        let outPath = parsed.values["--out"] ?? FileManager.default.currentDirectoryPath
        let outURL = URL(fileURLWithPath: outPath, isDirectory: true)
        do { try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true) }
        catch { FileHandle.standardError.write(Data("error: failed to create output directory '\(outPath)': \(error.localizedDescription)\n".utf8)); return 1 }

        let storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("tertia-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let store = SharedStateStore(primaryDirectory: storeDir)

        // The clock, the stamped snapshot, and the booked row come first: the shown sync time is never after the shown
        // time, and the booked row is a class that has not started.
        let live = parsed.flags.contains("--offline") ? nil : try? await PublicTimetableClient(store: store).fetchSchedule(clubId: 39, date: LondonCalendar.londonTodayIso(), forceRefresh: true)
        let scene = SampleData.previewScene(live: live, now: Date())
        let (previewDate, previewNow, selectedRow) = (scene.date, scene.now, scene.bookedRow)
        let sampleBookedId = selectedRow?.id ?? 1
        let prefs = TertiaPreferences(clubId: 39, clubName: "Canary Wharf", clubShortCode: "CANARY", period: .all, searchQuery: "")
        let snapshot: TimetableSnapshot
        do {
            try store.updatePreferences { $0 = prefs }
            snapshot = try store.mergeAndSaveSnapshot(clubId: scene.snapshot.clubId, clubs: scene.snapshot.clubs, clubName: scene.snapshot.clubName, clubShortCode: scene.snapshot.clubShortCode,
                                                      fetchedDays: scene.snapshot.days, fetchedRange: Array(scene.snapshot.days.keys), requestSeq: try store.reserveSnapshotSequence(),
                                                      syncedAt: previewNow, now: previewNow)
        }
        catch { FileHandle.standardError.write(Data("error: failed to seed preview store: \(error.localizedDescription)\n".utf8)); return 1 }

        func makePreviewModel(scheme: ColorScheme, openClubs: Bool = false, signedIn: Bool = false) -> ScheduleViewModel {
            let vm = ScheduleViewModel(store: store, keychain: KeychainStore(service: "club.tertia.macos.preview-\(UUID().uuidString)"))
            vm.selectedDate = previewDate; vm.themeOverride = scheme; vm.isClubMenuOpen = openClubs; vm.nowOverride = previewNow
            if signedIn {
                let member = MemberSession(token: "preview", id: 1, name: "Alex Morgan", email: "alex@example.com", homeClubId: 39, homeClubName: "Canary Wharf", expiresAt: "")
                vm.memberSession = member
                let booking = selectedRow.flatMap { row in LondonCalendar.parseWallTime(row.startTime).map { t in
                    MemberBooking(id: row.id, title: row.title, startDate: row.date + String(format: "T%02d:%02d:%02d", t.hour, t.minute, t.second),
                                  clubName: row.clubName, trainerName: row.trainer, eventAction: "cancel")
                } }
                vm.bookings = BookingsSnapshot(ownerKey: member.ownerKey ?? "", bookings: booking.map { [$0] } ?? [], syncedAt: previewNow)
            }
            return vm
        }

        let bookingModel = makePreviewModel(scheme: .dark, signedIn: true)
        print("preview clock: now \(LondonCalendar.formatSyncTime(previewNow)), synced \(snapshot.syncedAt(for: previewDate).map(LondonCalendar.formatSyncTime) ?? "never")")
        if let selectedRow { print("menubar-booking-dark.png badge: \(bookingModel.badge(for: selectedRow, now: previewNow).label)") }
        // The shipped menu with the shipped Quit button; `staticPreview` only freezes the clock and skips side effects.
        let menus: [(String, ScheduleViewModel)] = [("menubar-booking-dark.png", bookingModel), ("menubar-dark.png", makePreviewModel(scheme: .dark)),
                                                    ("menubar-club-open-dark.png", makePreviewModel(scheme: .dark, openClubs: true)), ("menubar-light.png", makePreviewModel(scheme: .light))]
        let menuRenders: [(String, AnyView)] = menus.map { name, vm in
            let menu = MenuBarScheduleView(model: vm, onQuit: {}, staticPreview: true, previewNow: previewNow)
            let controls = menu.controlSummary
            print("\(name) controls: \(controls.datePills) date pills, \(controls.clubRows) clubs, quit \(controls.hasQuit)")
            return (name, AnyView(menu))
        }
        let renders: [(String, AnyView)] = menuRenders + [
            ("widget-small-dark.png", AnyView(WidgetPreviewWrapper(width: 170, height: 170, scheme: .dark) { TertiaSmallWidgetView(snapshot: snapshot, preferences: prefs, bookedIds: [sampleBookedId], now: previewNow) })),
            ("widget-medium-dark.png", AnyView(WidgetPreviewWrapper(width: 364, height: 170, scheme: .dark) { TertiaMediumWidgetView(snapshot: snapshot, preferences: prefs, bookedIds: [sampleBookedId], now: previewNow) })),
            ("widget-medium-light.png", AnyView(WidgetPreviewWrapper(width: 364, height: 170, scheme: .light) { TertiaMediumWidgetView(snapshot: snapshot, preferences: prefs, bookedIds: [sampleBookedId], now: previewNow) })),
            ("widget-large-dark.png", AnyView(WidgetPreviewWrapper(width: 364, height: 382, scheme: .dark) { TertiaLargeWidgetView(snapshot: snapshot, preferences: prefs, bookedIds: [sampleBookedId], now: previewNow) })),
        ]

        for (filename, view) in renders {
            let renderer = ImageRenderer(content: view); renderer.scale = 2.0
            let fileURL = outURL.appendingPathComponent(filename)
            guard let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                FileHandle.standardError.write(Data("error: failed to render \(filename)\n".utf8)); return 1
            }
            do { try png.write(to: fileURL); print("Rendered \(fileURL.path) (\(png.count) bytes)") }
            catch { FileHandle.standardError.write(Data("error: failed to write \(fileURL.path): \(error.localizedDescription)\n".utf8)); return 1 }
        }
        return 0
    }
}
