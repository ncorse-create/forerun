import ForerunCore
import SwiftData
import SwiftUI

/// The home screen. Restraint is the feature.
///
/// Two sections and nothing else: what's due today, and the next three things coming. No
/// progress bar, no "you've done X of Y", no weekly summary, no count on anything. Marking
/// everything done leaves a calm screen, not a celebration.
struct TodayScreen: View {
    @Environment(AppEnvironment.self) private var app
    @State private var path = NavigationPath()
    @Query private var trackedEvents: [TrackedEvent]

    @State private var snoozeFailureMessage: String?

    /// Steps whose moment has arrived: due today, or overdue and still unresolved. Overdue ones
    /// are included deliberately — a step you did not act on yesterday has not stopped mattering.
    private var dueNow: [PrepStep] {
        let endOfToday = Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400)
        return trackedEvents
            .filter { $0.disappearedAt == nil && !$0.isDuplicate }
            .compactMap(\.plan)
            .flatMap(\.steps)
            .filter { step in
                guard step.state.isSchedulable || step.state == .fired else { return false }
                return (step.snoozedUntil ?? step.fireDate) < endOfToday
            }
            .sorted { ($0.snoozedUntil ?? $0.fireDate) < ($1.snoozedUntil ?? $1.fireDate) }
    }

    /// The next three events with anything still to do. Three, because this is a glance and not
    /// a list — the Events screen is where the rest lives.
    private var ahead: [TrackedEvent] {
        trackedEvents
            .filter { event in
                event.disappearedAt == nil
                    && !event.isDuplicate
                    && event.startDate > .now
                    && event.plan?.nextStep != nil
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if dueNow.isEmpty && ahead.isEmpty {
                    EmptyStateSentence(sentence: "Nothing needs you today.")
                        .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperBackground()
            .navigationTitle("Today")
            .refreshable { await app.refresh() }
            .navigationDestination(for: TrackedEvent.self) { event in
                PlanScreen(event: event)
            }
            .onChange(of: app.deepLinkedEvent) { _, event in
                // A tapped notification lands on the plan the reminder came from, not on
                // whatever screen the app happened to be showing.
                guard let event else { return }
                path = NavigationPath()
                path.append(event)
                app.deepLinkedEvent = nil
            }
            .alert(
                "No later left",
                isPresented: Binding(
                    get: { snoozeFailureMessage != nil },
                    set: { if !$0 { snoozeFailureMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { snoozeFailureMessage = nil }
            } message: {
                Text(snoozeFailureMessage ?? "")
            }
        }
    }

    private var list: some View {
        List {
            if !dueNow.isEmpty {
                Section {
                    ForEach(dueNow) { step in
                        nowRow(step)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    SectionHeading(title: "Now")
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if !ahead.isEmpty {
                Section {
                    ForEach(ahead) { event in
                        NavigationLink(value: event) {
                            AheadRow(event: event)
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    SectionHeading(title: "Ahead")
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

    @ViewBuilder
    private func nowRow(_ step: PrepStep) -> some View {
        if let event = step.plan?.event {
            NavigationLink(value: event) {
                NowRow(step: step, eventTitle: event.title)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button("Skip", systemImage: "xmark") {
                    Task { await app.resolve(step, as: .skipped) }
                }
                .tint(Palette.muted)
                Button("Snooze", systemImage: "clock") {
                    Task {
                        if await !app.snooze(step) {
                            snoozeFailureMessage = "This step can't move any later — "
                                + "\(event.title) is too close."
                        }
                    }
                }
                .tint(Palette.clay)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button("Done", systemImage: "checkmark") {
                    Task { await app.resolve(step, as: .done) }
                }
                .tint(Palette.amber)
            }
        }
    }
}

private struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(TypeRamp.micro())
            .tracking(0.8)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.hMargin)
            .padding(.top, Metrics.sectionSpacing)
            .padding(.bottom, 6)
            .background(Palette.paper)
    }
}

private struct NowRow: View {
    let step: PrepStep
    let eventTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Palette.forAudience(step.audience))
                .frame(width: Metrics.dotSize, height: Metrics.dotSize)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(step.effectiveCopy)
                    .font(TypeRamp.body())
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text(eventTitle.uppercased())
                    .font(TypeRamp.micro())
                    .tracking(0.6)
                    .foregroundStyle(Palette.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.hMargin)
        .padding(.vertical, Metrics.rowSpacing)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.effectiveCopy). For \(eventTitle).")
        .accessibilityHint("Double tap to open the plan")
    }
}

private struct AheadRow: View {
    let event: TrackedEvent

    private var nextActionLine: String? {
        guard let next = event.plan?.nextStep else { return nil }
        return next.effectiveCopy
    }

    private var whenLine: String {
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: Calendar.current.startOfDay(for: event.startDate)
        ).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(event.title)
                    .font(TypeRamp.eventTitleCompact())
                    .foregroundStyle(Palette.ink)
                Text("·")
                    .foregroundStyle(Palette.muted)
                Text(whenLine)
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
            }

            if let nextActionLine {
                Text(nextActionLine)
                    .font(TypeRamp.caption())
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.hMargin)
        .padding(.vertical, Metrics.rowSpacing)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(whenLine). Next: \(nextActionLine ?? "nothing")")
    }
}
