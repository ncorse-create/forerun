import ForerunCore
import SwiftData
import SwiftUI

/// Choose what Forerun pays attention to.
///
/// Everything in the 60-day window is listed, tracked or not. Tracked events carry an amber
/// rail on the leading edge — the same rail the Plan screen uses, so the visual language for
/// "Forerun is on this" is one thing throughout the app.
struct EventsScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Query private var trackedEvents: [TrackedEvent]

    @State private var confirmingUntrack: NormalizedEvent?
    @State private var showingRules = false
    @State private var showingSettings = false

    private var trackedSourceIDs: Set<String> {
        Set(trackedEvents.map(\.sourceID))
    }

    private var grouped: [(day: Date, events: [NormalizedEvent])] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: app.sync.browsableEvents) {
            calendar.startOfDay(for: $0.startDate)
        }
        return byDay
            .map { (day: $0.key, events: $0.value.sorted { $0.startDate < $1.startDate }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        NavigationStack {
            Group {
                if app.calendarAccessError != nil {
                    CalendarAccessGate()
                } else if app.sync.browsableEvents.isEmpty {
                    // Three genuinely different states, not one sentence covering all of them.
                    // "Tap an event" is wrong advice when there is no event to tap.
                    EmptyStateSentence(sentence: emptyStateSentence)
                        .frame(maxHeight: .infinity)
                } else {
                    eventList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperBackground()
            .navigationTitle("Events")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingRules = true
                    } label: {
                        Label("Tracking rules", systemImage: "line.3.horizontal.decrease")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingRules) { TrackingRulesSheet() }
            .sheet(isPresented: $showingSettings) { SettingsScreen() }
            .refreshable { await app.refresh() }
            .task { await app.refresh() }
            .confirmationDialog(
                "Stop tracking this event?",
                isPresented: Binding(
                    get: { confirmingUntrack != nil },
                    set: { if !$0 { confirmingUntrack = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Stop tracking", role: .destructive) {
                    if let event = confirmingUntrack {
                        Task { await app.untrack(event) }
                    }
                    confirmingUntrack = nil
                }
                Button("Keep it", role: .cancel) { confirmingUntrack = nil }
            } message: {
                Text("Its prep plan and any notes you wrote on it will be removed. "
                     + "Forerun won't track it again on its own.")
            }
        }
    }

    /// A `List`, not a `ScrollView`. `swipeActions` is a `List`-only modifier and silently does
    /// nothing anywhere else, so untrack-by-swipe would have been dead UI. Row insets, separators
    /// and backgrounds are all cleared so it still looks like the plain editorial list the design
    /// system asks for rather than a grouped iOS table.
    private var eventList: some View {
        List {
            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.events) { event in
                        row(for: event)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    DayHeader(day: group.day)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    /// Tapping an untracked event tracks it; tapping a tracked one opens its plan. The plan
    /// document said "tap again to untrack," but once an event has a ladder the thing you want
    /// from a tap is to *see* the ladder — untracking moved to a swipe, which is also where iOS
    /// users look for a destructive row action.
    @ViewBuilder
    private func row(for event: NormalizedEvent) -> some View {
        if let tracked = app.trackedEvent(for: event.sourceID) {
            NavigationLink {
                PlanScreen(event: tracked)
            } label: {
                EventRow(event: event, isTracked: true, showsDisclosure: true, onToggle: nil)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Untrack", systemImage: "minus.circle") {
                    confirmUntrack(tracked, event: event)
                }
                .tint(Palette.muted)
            }
        } else {
            EventRow(event: event, isTracked: false, showsDisclosure: false) {
                Task { await app.track(event) }
            }
        }
    }

    private func confirmUntrack(_ tracked: TrackedEvent, event: NormalizedEvent) {
        let hasWork = tracked.plan?.steps.contains(where: \.isUserOwned) == true
            || !tracked.scratchpad.isEmpty
        if hasWork {
            confirmingUntrack = event
        } else {
            Task { await app.untrack(event) }
        }
    }

    private var emptyStateSentence: String {
        if app.sync.isSyncing { return "Reading your calendar…" }
        let hasRules = !app.settings.trackedCalendarIDs.isEmpty
            || !app.settings.autoTrackFamilies.isEmpty
        if app.availableCalendars.isEmpty {
            return "No calendars connected yet."
        }
        if hasRules {
            return "Nothing on the calendars you picked for the next 60 days."
        }
        return "Nothing on your calendar for the next 60 days."
    }

}

private struct DayHeader: View {
    let day: Date

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        Text(label.uppercased())
            .font(TypeRamp.micro())
            .tracking(0.8)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.hMargin)
            .padding(.top, Metrics.sectionSpacing)
            .padding(.bottom, 8)
            .background(Palette.paper)
            .overlay(alignment: .bottom) { Hairline().padding(.leading, Metrics.hMargin) }
    }
}

struct EventRow: View {
    let event: NormalizedEvent
    let isTracked: Bool
    var showsDisclosure: Bool = false
    let onToggle: (() -> Void)?

    private var timeLabel: String {
        event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        Group {
            if let onToggle {
                Button(action: onToggle) { rowContent }
                    .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(timeLabel), \(event.calendarName)")
        .accessibilityValue(isTracked ? "Tracked" : "Not tracked")
        .accessibilityHint(isTracked ? "Double tap to open its plan" : "Double tap to plan the run-up")
        .accessibilityAddTraits(isTracked ? [.isSelected] : [])
    }

    private var rowContent: some View {
        HStack(alignment: .top, spacing: 12) {
                // The tracked rail sits inside the 20pt margin, so the optical left edge of the
                // row lines up with the day header and the hairline above it.
                Spacer().frame(width: Metrics.hMargin - 8)

                // Always occupies its width so rows do not shift when an event is tracked —
                // motion is for state changes, not for layout.
                Rectangle()
                    .fill(isTracked ? Palette.amber : Color.clear)
                    .frame(width: 3)
                    .clipShape(.rect(cornerRadius: 1.5))

                Circle()
                    .fill(Palette.forColorFamily(event.colorFamily))
                    .frame(width: Metrics.dotSize, height: Metrics.dotSize)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(TypeRamp.eventTitleCompact())
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(timeLabel)
                        Text("·")
                        Text(event.calendarName)
                        if event.hasRecurrenceRules {
                            Text("·")
                            Text("repeats")
                        }
                    }
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
                }

            Spacer(minLength: 8)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.hairline)
                    .padding(.top, 4)
            }
        }
        .padding(.trailing, Metrics.hMargin)
        .padding(.vertical, Metrics.rowSpacing)
        .contentShape(.rect)
    }
}

/// Calendar access is missing. Every case gets its own sentence and its own way forward —
/// "denied" and "write-only" are genuinely different problems with different fixes.
struct CalendarAccessGate: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL

    private var message: String {
        switch app.calendarAccessError {
        case .denied:
            "Forerun needs to read your calendar to know what's coming. You can turn that back "
            + "on in Settings."
        case .restricted:
            "Calendar access is turned off by a profile on this iPhone, so Forerun can't read "
            + "your events."
        case .writeOnlyAccess:
            "Forerun can add to your calendar but can't read it, so it can't see what's coming. "
            + "Switching to full access in Settings fixes it."
        default:
            "Forerun plans the run-up to the events you pick. Connect a calendar to start."
        }
    }

    private var isRecoverableInSettings: Bool {
        app.calendarAccessError == .denied || app.calendarAccessError == .writeOnlyAccess
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(message)
                .font(TypeRamp.body())
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)

            if isRecoverableInSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.amber)
            } else if app.calendarAccessError == .notDetermined {
                Button("Connect Apple Calendar") {
                    Task { await app.connectAppleCalendar() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.amber)
            }
        }
        .padding(.horizontal, Metrics.hMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
