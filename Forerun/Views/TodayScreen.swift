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

    /// How far back an unresolved step keeps appearing in Now.
    ///
    /// A step you did not act on yesterday has not stopped mattering — but without a floor,
    /// every unresolved step from every event of the past month sat in Now permanently, and the
    /// only way to clear it was to swipe each one. That is a clearing ritual on the home screen,
    /// which is exactly what locked decision 5 forbids. Three days keeps "yesterday" while
    /// letting genuinely stale work fall away on its own.
    static let overdueGraceDays = 3

    /// Steps whose moment has arrived: due today, or overdue within the grace window.
    private var dueNow: [PrepStep] {
        let calendar = Calendar.current
        let endOfToday = calendar.startOfDay(for: .now).addingTimeInterval(86_400)
        let floor = calendar.date(byAdding: .day, value: -Self.overdueGraceDays, to: .now) ?? .distantPast

        return trackedEvents
            .filter { $0.disappearedAt == nil && !$0.isDuplicate }
            .compactMap(\.plan)
            .flatMap(\.steps)
            .filter { step in
                guard step.state.isSchedulable || step.state == .fired else { return false }
                let fireDate = step.snoozedUntil ?? step.fireDate
                guard fireDate < endOfToday, fireDate >= floor else { return false }
                // A pre-event step for something that has already happened is noise, not work.
                if let event = step.plan?.event, step.offsetSeconds < 0, event.startDate < .now {
                    return false
                }
                return true
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
                if dueNow.isEmpty && ahead.isEmpty && !app.notificationsAreBlocked {
                    EmptyStateSentence(sentence: "Nothing needs you today.")
                        .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperBackground()
            .safeAreaInset(edge: .bottom) {
                UndoBanner()
                    .animation(.easeOut(duration: 0.2), value: app.pendingUndo)
            }
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
            if app.notificationsAreBlocked {
                NotificationsOffBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

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

/// Reminders cannot arrive. Said once, plainly, on the screen that would otherwise look normal.
private struct NotificationsOffBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminders are turned off")
                .font(TypeRamp.bodyEmphasis())
                .foregroundStyle(Palette.ink)
            Text("Forerun can still plan the run-up, but nothing will reach you until you turn "
                 + "notifications back on.")
                .font(TypeRamp.caption())
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(TypeRamp.micro())
            .foregroundStyle(Palette.amber)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.paperSunk, in: .rect(cornerRadius: 10))
        .padding(.horizontal, Metrics.hMargin)
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
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
