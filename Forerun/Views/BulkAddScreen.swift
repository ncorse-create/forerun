import ForerunCore
import SwiftData
import SwiftUI

/// Pick a lot of events at once, from a calendar.
///
/// Tapping events one at a time on the Events list is fine for one Sunday and miserable for a
/// term. This is the same decision taken in bulk: months laid out as grids, tap the days you care
/// about, tick the events on them, apply once.
///
/// It is a **two-way** screen rather than an add-only one. Every event carries a checkbox showing
/// whether it is tracked, so unticking a tracked event removes it — which means the same screen
/// that plans a term can also clear one, without hunting for each event again.
struct BulkAddScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Query private var trackedEvents: [TrackedEvent]

    /// Days the user has opened. Their events are listed below the grids.
    @State private var selectedDays: Set<Date> = []
    /// The desired tracked state, keyed by source id. Only holds entries the user has changed.
    @State private var desired: [String: Bool] = [:]
    @State private var isApplying = false

    private var calendar: Calendar { Calendar.current }

    private var trackedSourceIDs: Set<String> {
        Set(trackedEvents.filter { $0.disappearedAt == nil }.map(\.sourceID))
    }

    private var eventsByDay: [Date: [NormalizedEvent]] {
        Dictionary(grouping: app.sync.browsableEvents) { calendar.startOfDay(for: $0.startDate) }
    }

    /// Every month the 60-day window touches, in order.
    private var months: [Date] {
        let starts = app.sync.browsableEvents.map(\.startDate)
        guard let earliest = starts.min(), let latest = starts.max() else {
            return [startOfMonth(for: .now)]
        }
        var result: [Date] = []
        var cursor = startOfMonth(for: min(earliest, .now))
        let end = startOfMonth(for: latest)
        while cursor <= end, result.count < 24 {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func startOfMonth(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    // MARK: Pending changes

    private func isChecked(_ event: NormalizedEvent) -> Bool {
        desired[event.sourceID] ?? trackedSourceIDs.contains(event.sourceID)
    }

    private var toTrack: [NormalizedEvent] {
        app.sync.browsableEvents.filter { event in
            desired[event.sourceID] == true && !trackedSourceIDs.contains(event.sourceID)
        }
    }

    private var toUntrack: [NormalizedEvent] {
        app.sync.browsableEvents.filter { event in
            desired[event.sourceID] == false && trackedSourceIDs.contains(event.sourceID)
        }
    }

    private var hasChanges: Bool { !toTrack.isEmpty || !toUntrack.isEmpty }

    private var summary: String {
        switch (toTrack.count, toUntrack.count) {
        case (0, 0): "Nothing selected"
        case (let add, 0): "Track \(add) event\(add == 1 ? "" : "s")"
        case (0, let remove): "Stop tracking \(remove) event\(remove == 1 ? "" : "s")"
        case (let add, let remove): "Track \(add), stop \(remove)"
        }
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                        ForEach(months, id: \.self) { month in
                            MonthGrid(
                                month: month,
                                eventsByDay: eventsByDay,
                                trackedSourceIDs: trackedSourceIDs,
                                selectedDays: selectedDays,
                                onToggleDay: toggleDay(_:)
                            )
                        }

                        if selectedDays.isEmpty {
                            Text("Tap a day to see what's on it. Days with a dot have events; "
                                 + "an amber dot means something on that day is already tracked.")
                                .font(TypeRamp.caption())
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, Metrics.hMargin)
                                .padding(.top, 8)
                        } else {
                            ForEach(selectedDays.sorted(), id: \.self) { day in
                                DaySection(
                                    day: day,
                                    events: eventsByDay[day] ?? [],
                                    isChecked: isChecked(_:),
                                    onToggle: toggleEvent(_:),
                                    onSelectAll: { setAll(on: day, to: true) },
                                    onSelectNone: { setAll(on: day, to: false) }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.bottom, 24)
                }

                if hasChanges {
                    applyBar
                }
            }
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle("Add in bulk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !selectedDays.isEmpty {
                        Button("Clear days") { selectedDays = [] }
                            .font(TypeRamp.micro())
                    }
                }
            }
        }
    }

    private var applyBar: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack {
                Text(summary)
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button {
                    Task { await apply() }
                } label: {
                    Text(isApplying ? "Working…" : "Apply")
                        .font(TypeRamp.bodyEmphasis())
                        .foregroundStyle(Palette.paper)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Palette.amber, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(isApplying)
            }
            .padding(.horizontal, Metrics.hMargin)
            .padding(.vertical, 12)
            .background(Palette.paper)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Actions

    private func toggleDay(_ day: Date) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
    }

    private func toggleEvent(_ event: NormalizedEvent) {
        let next = !isChecked(event)
        // Setting it back to where it started clears the pending change rather than recording a
        // no-op, so the summary counts only real work.
        if next == trackedSourceIDs.contains(event.sourceID) {
            desired[event.sourceID] = nil
        } else {
            desired[event.sourceID] = next
        }
    }

    private func setAll(on day: Date, to value: Bool) {
        for event in eventsByDay[day] ?? [] {
            if value == trackedSourceIDs.contains(event.sourceID) {
                desired[event.sourceID] = nil
            } else {
                desired[event.sourceID] = value
            }
        }
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }

        let adding = toTrack
        let removing = toUntrack

        for event in removing {
            await app.untrack(event)
        }
        if !adding.isEmpty {
            await app.trackBulk(adding)
        }
        desired = [:]
        dismiss()
    }
}

// MARK: - A month

private struct MonthGrid: View {
    let month: Date
    let eventsByDay: [Date: [NormalizedEvent]]
    let trackedSourceIDs: Set<String>
    let selectedDays: Set<Date>
    let onToggleDay: (Date) -> Void

    private var calendar: Calendar { Calendar.current }

    private var title: String {
        month.formatted(.dateTime.month(.wide).year())
    }

    /// Leading blanks so the first of the month lands under the right weekday.
    private var leadingBlanks: Int {
        let weekday = calendar.component(.weekday, from: month)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    private var days: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month)
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TypeRamp.eventTitleCompact())
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Metrics.hMargin)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(TypeRamp.micro())
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }

                ForEach(0..<leadingBlanks, id: \.self) { index in
                    Color.clear
                        .frame(height: 44)
                        .accessibilityHidden(true)
                        .id("blank-\(index)")
                }

                ForEach(days, id: \.self) { day in
                    let dayStart = calendar.startOfDay(for: day)
                    DayCell(
                        day: dayStart,
                        events: eventsByDay[dayStart] ?? [],
                        trackedSourceIDs: trackedSourceIDs,
                        isSelected: selectedDays.contains(dayStart),
                        onTap: { onToggleDay(dayStart) }
                    )
                }
            }
            .padding(.horizontal, Metrics.hMargin)
        }
    }
}

private struct DayCell: View {
    let day: Date
    let events: [NormalizedEvent]
    let trackedSourceIDs: Set<String>
    let isSelected: Bool
    let onTap: () -> Void

    private var trackedCount: Int {
        events.filter { trackedSourceIDs.contains($0.sourceID) }.count
    }

    private var dayNumber: String {
        day.formatted(.dateTime.day())
    }

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Text(dayNumber)
                    .font(TypeRamp.caption())
                    .foregroundStyle(isSelected ? Palette.paper : Palette.ink)

                // One dot for "something here", amber when any of it is already tracked. A dot
                // per event would be unreadable on a busy day and is not what the tap is for.
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                    .opacity(events.isEmpty ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                if isSelected {
                    Circle().fill(Palette.amber).frame(width: 38, height: 38)
                } else if isToday {
                    Circle().stroke(Palette.hairline, lineWidth: 1).frame(width: 38, height: 38)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(events.isEmpty)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "Open" : "")
        .accessibilityHint(events.isEmpty ? "" : "Double tap to see this day's events")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var dotColor: Color {
        if isSelected { return Palette.paper }
        return trackedCount > 0 ? Palette.amber : Palette.muted
    }

    private var accessibilityLabel: String {
        let date = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        switch (events.count, trackedCount) {
        case (0, _): return "\(date), nothing on"
        case (let total, 0): return "\(date), \(total) event\(total == 1 ? "" : "s")"
        case (let total, let tracked):
            return "\(date), \(total) event\(total == 1 ? "" : "s"), \(tracked) tracked"
        }
    }
}

// MARK: - A day's events

private struct DaySection: View {
    let day: Date
    let events: [NormalizedEvent]
    let isChecked: (NormalizedEvent) -> Bool
    let onToggle: (NormalizedEvent) -> Void
    let onSelectAll: () -> Void
    let onSelectNone: () -> Void

    private var title: String {
        day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(TypeRamp.micro())
                    .tracking(0.8)
                    .foregroundStyle(Palette.muted)
                Spacer()
                if !events.isEmpty {
                    Button("All", action: onSelectAll)
                        .font(TypeRamp.micro())
                        .foregroundStyle(Palette.amber)
                        .padding(.vertical, 8)
                    Button("None", action: onSelectNone)
                        .font(TypeRamp.micro())
                        .foregroundStyle(Palette.muted)
                        .padding(.vertical, 8)
                        .padding(.leading, 10)
                }
            }

            if events.isEmpty {
                Text("Nothing on this day.")
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
            } else {
                ForEach(events.sorted { $0.startDate < $1.startDate }) { event in
                    BulkEventRow(
                        event: event,
                        isChecked: isChecked(event),
                        onToggle: { onToggle(event) }
                    )
                }
            }
        }
        .padding(.horizontal, Metrics.hMargin)
    }
}

private struct BulkEventRow: View {
    let event: NormalizedEvent
    let isChecked: Bool
    let onToggle: () -> Void

    private var timeLabel: String {
        event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isChecked ? Palette.amber : Palette.hairline)
                    .imageScale(.large)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(TypeRamp.body())
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(timeLabel) · \(event.calendarName)")
                        .font(TypeRamp.caption())
                        .foregroundStyle(Palette.muted)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(timeLabel), \(event.calendarName)")
        .accessibilityValue(isChecked ? "Selected" : "Not selected")
        .accessibilityAddTraits(isChecked ? [.isSelected] : [])
    }
}

// MARK: - Undo

/// The undo affordance. Sits above the tab bar, says what happened, and gets out of the way.
///
/// It exists because tracking is a single tap with no confirmation — which is right, and which
/// makes a mistap free only if it is also free to reverse.
struct UndoBanner: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        if let undo = app.pendingUndo {
            HStack(spacing: 12) {
                Text(undo.sentence)
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.paper)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button("Undo") {
                    Task { await app.performUndo() }
                }
                .font(TypeRamp.bodyEmphasis())
                .foregroundStyle(Palette.amber)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Palette.ink, in: .rect(cornerRadius: 12))
            .padding(.horizontal, Metrics.hMargin)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(undo.sentence)
            .accessibilityHint("Double tap Undo to reverse this")
        }
    }
}
