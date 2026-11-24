import SwiftUI
import TertiaCore

struct ClassReminderDrawer: View {
    @ObservedObject var model: ScheduleViewModel
    let session: ClassSession
    let palette: TertiaPalette
    let now: Date
    let staticPreview: Bool

    var body: some View {
        let active = model.reminders(for: session, now: now)
        let activeMinutes = Set(active.map(\.leadMinutes))
        let exactStart: Date? = {
            if case .exact(let dt) = LondonCalendar.resolveLondonWallTime(dateIso: session.date, hhmm: session.startTime) { return dt }
            return nil
        }()
        let customActive = active.filter { !ClassReminder.presetLeadMinutes.contains($0.leadMinutes) }

        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Remind before start (5m to 48h)").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.muted)
                Spacer()
                if !active.isEmpty {
                    Button("Clear") { Task { await model.clearReminders(for: session) } }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.warningStatus)
                }
            }

            HStack(spacing: 4) {
                ForEach(ClassReminder.presetLeadMinutes, id: \.self) { mins in
                    let isOn = activeMinutes.contains(mins)
                    let available = exactStart.map { $0.addingTimeInterval(-TimeInterval(mins) * 60) > now } ?? false
                    Button { Task { await model.togglePresetReminder(for: session, leadMinutes: mins) } } label: {
                        Text(ClassReminder.formatLeadTime(minutes: mins))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isOn ? palette.pillSelectedText : (available ? palette.ink : palette.faint))
                            .padding(.horizontal, 7).padding(.vertical, 3.5)
                            .tertiaSurface(fill: isOn ? palette.warningStatus : palette.pillSurface, border: isOn ? palette.warningStatus : palette.border, radius: 6)
                    }
                    .buttonStyle(.plain).disabled(!isOn && !available).opacity((!isOn && !available) ? 0.45 : 1.0)
                }
            }

            HStack(spacing: 5) {
                Text("Custom").font(.system(size: 10)).foregroundStyle(palette.muted)
                numberBox(text: $model.customReminderHours, width: 32)
                Text("h").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.muted)
                numberBox(text: $model.customReminderMinutes, width: 32)
                Text("m").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.muted)
                Button { Task { await model.addCustomReminder(for: session) } } label: {
                    Text("Add").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.pillSelectedText)
                        .padding(.horizontal, 9).padding(.vertical, 3.5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.pillSelected))
                }
                .buttonStyle(.plain)
                Spacer()
            }

            if !customActive.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(customActive) { reminder in
                            Button { Task { await model.removeReminder(id: reminder.id) } } label: {
                                HStack(spacing: 4) {
                                    Text(ClassReminder.formatLeadTime(minutes: reminder.leadMinutes))
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced)).foregroundStyle(palette.warningStatus)
                                .padding(.horizontal, 7).padding(.vertical, 2.5)
                                .tertiaSurface(fill: palette.warningStatus.opacity(0.14), border: palette.warningStatus.opacity(0.4), radius: 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .tertiaSurface(fill: palette.pillSurface, border: palette.border, radius: 9)
    }

    @ViewBuilder
    private func numberBox(text: Binding<String>, width: CGFloat) -> some View {
        let base = Group {
            if staticPreview {
                Text(text.wrappedValue).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink)
            } else {
                TextField("0", text: text).textFieldStyle(.plain).focusEffectDisabled()
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink).multilineTextAlignment(.center)
            }
        }
        base.frame(width: width).padding(.horizontal, 4).padding(.vertical, 3)
            .tertiaSurface(fill: palette.card, border: palette.border, radius: 6)
    }
}

struct RemindersOverviewPanel: View {
    @ObservedObject var model: ScheduleViewModel
    let palette: TertiaPalette
    let now: Date

    var body: some View {
        let list = model.upcomingReminders(now: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("UPCOMING REMINDERS (\(list.count))").font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(1.0).foregroundStyle(palette.muted)
                Spacer()
                Text("5m - 48h").font(.system(size: 9, design: .monospaced)).foregroundStyle(palette.faint)
            }
            if list.isEmpty {
                Text("Tap the bell on any future class card to schedule a local macOS alert.").font(.system(size: 10.5)).foregroundStyle(palette.muted)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(list) { reminder in reminderRow(reminder) }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .tertiaSurface(fill: palette.pillSurface, border: palette.border, radius: 10)
    }

    private func reminderRow(_ reminder: ClassReminder) -> some View {
        HStack(spacing: 8) {
            Button { model.openReminderTarget(clubId: reminder.clubId, date: reminder.date) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(reminder.title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1)
                        Text(ClassReminder.formatLeadTime(minutes: reminder.leadMinutes))
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(palette.warningStatus)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .tertiaSurface(fill: palette.warningStatus.opacity(0.14), border: palette.warningStatus.opacity(0.35), radius: 5)
                    }
                    Text("\(reminder.clubName) · \(reminder.date) \(reminder.startTime) · Alerts \(LondonCalendar.formatWeekdayTime(reminder.fireAt))")
                        .font(.system(size: 9.5)).foregroundStyle(palette.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { Task { await model.removeReminder(id: reminder.id) } } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.faint).frame(width: 20, height: 20)
            }
            .buttonStyle(.plain).help("Remove reminder")
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .tertiaSurface(fill: palette.card, border: palette.border, radius: 8)
    }
}
