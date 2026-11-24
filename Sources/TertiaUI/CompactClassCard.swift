import SwiftUI
import TertiaCore

public struct CompactClassCard: View {
    /// What the trailing badge shows; `isAction` badges are buttons.
    public enum Badge: Equatable, Sendable {
        case busy, confirmLateCancel, bookedCancel, book, booked
        case status(BookingWindowStatus)

        public var label: String {
            switch self {
            case .busy: "..."
            case .confirmLateCancel: "LATE (<=3H) · CONFIRM?"
            case .bookedCancel: "BOOKED · CANCEL"
            case .book: "BOOK"
            case .booked: "BOOKED"
            case .status(let status): status.badgeLabel
            }
        }

        /// The one definition of which badges are buttons; rendering follows it.
        public var isAction: Bool {
            switch self {
            case .busy, .confirmLateCancel, .bookedCancel, .book: true
            case .booked, .status: false
            }
        }

        /// Chip colors (foreground, fill, border) for every badge except `.status`, which renders as a `StatusPill`.
        func chipColors(_ palette: TertiaPalette) -> (fg: Color, bg: Color, border: Color) {
            switch self {
            case .busy: (palette.muted, palette.pillSurface, palette.border)
            case .confirmLateCancel: (palette.warningStatus, palette.warningStatus.opacity(0.16), palette.warningStatus.opacity(0.45))
            case .bookedCancel, .booked, .status: (palette.openStatus, palette.openStatus.opacity(0.14), palette.openStatus.opacity(0.38))
            case .book: (palette.pillSelectedText, palette.openStatus, .clear)
            }
        }
    }

    /// A booked row offers Cancel whenever `canCancelBooked` (judged from the booking's own start stamp), whatever the
    /// public row's wall time says. An unbooked row offers Book only while `.open`, so a started or clock-change
    /// (`.invalidTime`, shown as UNAVAILABLE) row never does.
    public static func badge(status: BookingWindowStatus, isBooked: Bool, canCancelBooked: Bool, confirmingLateCancel: Bool, isBusy: Bool, hasAction: Bool) -> Badge {
        guard hasAction, isBooked ? canCancelBooked : status == .open else { return isBooked ? .booked : .status(status) }
        if isBusy { return .busy }
        return isBooked ? (confirmingLateCancel ? .confirmLateCancel : .bookedCancel) : .book
    }

    public let session: ClassSession
    public let palette: TertiaPalette
    public let now: Date
    public let dense, isBooked, isBusy, confirmingLateCancel, canCancelBooked: Bool
    public let activeReminderLabels: [String]
    public let isReminderPickerOpen: Bool
    public let onToggleReminderPicker: (() -> Void)?
    public let onAction: (() -> Void)?

    public init(session: ClassSession, palette: TertiaPalette, now: Date = Date(), dense: Bool = false, isBooked: Bool = false, isBusy: Bool = false,
                confirmingLateCancel: Bool = false, canCancelBooked: Bool = true, activeReminderLabels: [String] = [], isReminderPickerOpen: Bool = false,
                onToggleReminderPicker: (() -> Void)? = nil, onAction: (() -> Void)? = nil) {
        self.session = session; self.palette = palette; self.now = now; self.dense = dense
        self.isBooked = isBooked; self.isBusy = isBusy; self.confirmingLateCancel = confirmingLateCancel
        self.canCancelBooked = canCancelBooked; self.activeReminderLabels = activeReminderLabels
        self.isReminderPickerOpen = isReminderPickerOpen; self.onToggleReminderPicker = onToggleReminderPicker; self.onAction = onAction
    }

    public var body: some View {
        let status = LondonCalendar.bookingWindowStatus(for: session, now: now)
        VStack(alignment: .leading, spacing: dense ? 2 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title).font(.system(size: dense ? 12.5 : 13.5, weight: .regular, design: .serif)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(session.startTime) - \(session.endTime)").font(.system(size: dense ? 10.5 : 11, weight: .medium, design: .monospaced)).monospacedDigit().foregroundStyle(palette.ink)
            }
            HStack(alignment: .center, spacing: 6) {
                Text(session.trainer.isEmpty ? "Instructor TBA" : session.trainer).font(.system(size: dense ? 10.5 : 11)).foregroundStyle(palette.muted).lineLimit(1)
                Spacer(minLength: 6)
                if !dense, let onToggleReminderPicker {
                    reminderBellButton(action: onToggleReminderPicker).fixedSize(horizontal: true, vertical: false)
                }
                trailingBadge(status: status).fixedSize(horizontal: true, vertical: false)
                Text("\(session.durationMinutes)m").font(.system(size: 10, design: .monospaced)).monospacedDigit().foregroundStyle(palette.faint).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, dense ? 9 : 11).padding(.vertical, dense ? 6 : 8)
        .tertiaSurface(fill: palette.card, border: isBooked ? palette.openStatus.opacity(0.42) : palette.border, radius: TertiaMetrics.cardRadius)
    }

    @ViewBuilder
    private func reminderBellButton(action: @escaping () -> Void) -> some View {
        let hasActive = !activeReminderLabels.isEmpty
        let compactLabel = activeReminderLabels.first.map { first in
            activeReminderLabels.count > 1 ? "\(first)+\(activeReminderLabels.count - 1)" : first
        }
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: hasActive || isReminderPickerOpen ? "bell.fill" : "bell").font(.system(size: 9, weight: .semibold))
                if let compactLabel {
                    Text(compactLabel).font(.system(size: 8.5, weight: .semibold, design: .monospaced)).lineLimit(1)
                }
            }
            .foregroundStyle(hasActive ? palette.warningStatus : (isReminderPickerOpen ? palette.ink : palette.faint))
            .padding(.horizontal, hasActive ? 6 : 5).frame(height: 19)
            .tertiaSurface(
                fill: hasActive ? palette.warningStatus.opacity(0.14) : (isReminderPickerOpen ? palette.pillSurface : .clear),
                border: hasActive ? palette.warningStatus.opacity(isReminderPickerOpen ? 0.65 : 0.35) : (isReminderPickerOpen ? palette.border : .clear),
                radius: 9.5
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help("Set class reminder")
    }

    @ViewBuilder
    private func trailingBadge(status: BookingWindowStatus) -> some View {
        let badge = Self.badge(status: status, isBooked: isBooked, canCancelBooked: canCancelBooked, confirmingLateCancel: confirmingLateCancel, isBusy: isBusy, hasAction: onAction != nil)
        if case .status(let status) = badge {
            StatusPill(status: status, palette: palette)
        } else {
            let colors = badge.chipColors(palette)
            let chip = StatusChip(label: badge.label, fg: colors.fg, bg: colors.bg, border: colors.border)
            if badge.isAction {
                Button { onAction?() } label: { chip }.buttonStyle(.plain).disabled(isBusy)
            } else {
                chip
            }
        }
    }
}

public struct StatusPill: View {
    public let status: BookingWindowStatus
    public let palette: TertiaPalette

    public init(status: BookingWindowStatus, palette: TertiaPalette) {
        self.status = status; self.palette = palette
    }

    public var body: some View {
        let fg: Color = switch status { case .open: palette.openStatus; case .openingSoon: palette.warningStatus; case .started, .upcoming, .invalidTime: palette.muted }
        let bg: Color = switch status { case .open: palette.openStatus.opacity(0.13); case .openingSoon: palette.warningStatus.opacity(0.14); case .started, .upcoming, .invalidTime: palette.pillSurface }
        StatusChip(label: status.badgeLabel, fg: fg, bg: bg, border: .clear)
    }
}

struct StatusChip: View {
    let label: String
    let fg, bg, border: Color

    var body: some View {
        Text(label).font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(border, lineWidth: border == .clear ? 0 : 1))
            .lineLimit(1)
    }
}
