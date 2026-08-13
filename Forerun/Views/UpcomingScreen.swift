import ForerunCore
import SwiftData
import SwiftUI

/// The shape of what is building.
///
/// Neither Today nor Events answers "what is coming, and where does the load sit?" — one is a
/// glance at now, the other is a picker. This is the week first, then the month on scroll, and it
/// is the only screen that shows the daily cap being kept rather than merely promised.
struct UpcomingScreen: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var path = NavigationPath()
    @Query private var trackedEvents: [TrackedEvent]

    /// Monday first, as the design draws it.
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private var liveEvents: [TrackedEvent] {
        trackedEvents.filter { $0.disappearedAt == nil && !$0.isDuplicate }
    }

    /// Every reminder still to come, reduced to what the week view needs.
    private var asks: [ScheduledAsk] {
        liveEvents.flatMap { event -> [ScheduledAsk] in
            (event.plan?.steps ?? [])
                .filter { $0.state.isSchedulable || $0.state == .fired }
                .map { step in
                    ScheduledAsk(
                        fireDate: step.snoozedUntil ?? step.fireDate,
                        // Where the playbook offset alone would have put it. Comparing this to
                        // where it actually landed is how the cap sentence knows what moved,
                        // without the engine having to keep a record of its own decisions.
                        idealDate: event.startDate.addingTimeInterval(step.offsetSeconds),
                        audience: step.audience,
                        wasMovedByUser: step.userPinnedTime || step.snoozedUntil != nil
                    )
                }
        }
    }

    private var weekStart: Date {
        calendar.dateInterval(of: .weekOfYear, for: .now)?.start
            ?? calendar.startOfDay(for: .now)
    }

    private var weekDays: [DayLoad] {
        WeekShape.days(from: weekStart, count: 7, asks: asks, calendar: calendar)
    }

    private var capSentence: String? {
        CapNarrator.sentence(
            for: weekDays,
            budget: app.settings.dailyNotificationBudget,
            calendar: calendar
        )
    }

    /// Events with anything still to do inside this week.
    private var thisWeeksEvents: [TrackedEvent] {
        guard let end = calendar.date(byAdding: .day, value: 7, to: weekStart) else { return [] }
        return liveEvents
            .filter { event in
                (event.plan?.steps ?? []).contains { step in
                    guard step.state.isSchedulable || step.state == .fired else { return false }
                    let fire = step.snoozedUntil ?? step.fireDate
                    return fire >= weekStart && fire < end
                }
            }
            .sorted { $0.startDate < $1.startDate }
    }

    /// Remaining weeks of the current month, after this one.
    private var laterWeeks: [(start: Date, events: [(event: TrackedEvent, date: Date, audience: Audience)])] {
        guard let monthEnd = calendar.dateInterval(of: .month, for: .now)?.end,
              let firstLater = calendar.date(byAdding: .day, value: 7, to: weekStart)
        else { return [] }

        var result: [(Date, [(TrackedEvent, Date, Audience)])] = []
        var cursor = firstLater
        while cursor < monthEnd {
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            var rows: [(TrackedEvent, Date, Audience)] = []
            for event in liveEvents {
                let inWeek = (event.plan?.steps ?? [])
                    .filter { $0.state.isSchedulable || $0.state == .fired }
                    .map { (step: $0, fire: $0.snoozedUntil ?? $0.fireDate) }
                    .filter { $0.fire >= cursor && $0.fire < next }
                    .sorted { $0.fire < $1.fire }
                if let first = inWeek.first {
                    rows.append((event, first.fire, first.step.audience))
                }
            }
            if !rows.isEmpty {
                result.append((cursor, rows.sorted { $0.1 < $1.1 }))
            }
            cursor = next
        }
        return result.map { (start: $0.0, events: $0.1.map { (event: $0.0, date: $0.1, audience: $0.2) }) }
    }

    private var monthTotal: Int {
        guard let month = calendar.dateInterval(of: .month, for: .now) else { return 0 }
        return asks.filter { $0.fireDate >= month.start && $0.fireDate < month.end }.count
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("The week, then the month.")
                        .font(.system(.subheadline))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if asks.isEmpty {
                        EmptyStateSentence(sentence: "Nothing is building. Track an event and its "
                                           + "run-up will show up here.")
                            .padding(.top, 40)
                    } else {
                        week
                        month
                    }
                }
                .padding(.horizontal, Metrics.hMargin)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .fieldBackground()
            .navigationTitle("Upcoming")
            .refreshable { await app.refresh() }
            .navigationDestination(for: TrackedEvent.self) { event in
                PlanScreen(event: event)
            }
        }
    }

    // MARK: The week

    @ViewBuilder private var week: some View {
        EyebrowRow(title: "This week") {
            Text(weekRangeLabel)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)

        // Seven across is unreadable at accessibility sizes — each column would be a few points
        // wide. The strip becomes a vertical list of day rows instead of compressing.
        if typeSize.isAccessibilitySize {
            VStack(spacing: 6) {
                ForEach(weekDays) { day in
                    DayRow(
                        day: day,
                        isToday: calendar.isDateInToday(day.day),
                        isAtCap: day.isAtCap(app.settings.dailyNotificationBudget)
                    )
                }
            }
        } else {
            HStack(spacing: 6) {
                ForEach(weekDays) { day in
                    DayTile(
                        day: day,
                        isToday: calendar.isDateInToday(day.day),
                        isAtCap: day.isAtCap(app.settings.dailyNotificationBudget)
                    )
                }
            }
        }

        if let capSentence {
            Text(capSentence)
                .font(.system(.footnote))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
        }

        if !thisWeeksEvents.isEmpty {
            VStack(spacing: 12) {
                ForEach(thisWeeksEvents) { event in
                    Button { path.append(event) } label: {
                        UpcomingEventCard(event: event, cap: app.settings.maxStepsPerEvent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 18)
        }
    }

    private var weekRangeLabel: String {
        guard let end = calendar.date(byAdding: .day, value: 6, to: weekStart) else { return "" }
        let start = weekStart.formatted(.dateTime.day())
        let finish = end.formatted(.dateTime.day().month(.abbreviated))
        return "\(start)—\(finish)".uppercased()
    }

    // MARK: The month

    @ViewBuilder private var month: some View {
        EyebrowRow(title: "The month") {
            Text(Date.now.formatted(.dateTime.month(.wide)).uppercased())
        }
        .padding(.top, 22)
        .padding(.bottom, 8)

        MonthGrid(asks: asks, total: monthTotal, calendar: calendar)

        if !laterWeeks.isEmpty {
            EyebrowRow("Later in \(Date.now.formatted(.dateTime.month(.wide)))")
                .padding(.top, 20)
                .padding(.bottom, 8)

            VStack(spacing: 12) {
                ForEach(laterWeeks, id: \.start) { week in
                    WeekContainer(start: week.start, rows: week.events) { event in
                        path.append(event)
                    }
                }
            }
        }
    }
}

// MARK: - Day tile

/// One day of the week strip. The load bars are one per scheduled reminder, coloured by who the
/// ask is for — so the strip reads as "who am I contacting, and when" rather than a bar chart.
private struct DayTile: View {
    let day: DayLoad
    let isToday: Bool
    let isAtCap: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    private var weekdayInitial: String {
        String(day.day.formatted(.dateTime.weekday(.narrow)).prefix(1))
    }

    var body: some View {
        VStack(spacing: 5) {
            Text(weekdayInitial)
                .font(.system(.caption2, weight: isToday ? .semibold : .regular))
                .foregroundStyle(isToday ? Palette.ink : Palette.muted)

            Text(day.day.formatted(.dateTime.day()))
                .font(.system(isToday ? .subheadline : .footnote, design: .serif))
                .fontWeight(isToday ? .semibold : .regular)
                .foregroundStyle(Palette.ink)

            // Fixed-size graphics, deliberately: these are the one thing on the screen that may
            // keep its height at large type, because they carry no text.
            HStack(spacing: 2) {
                if day.audiences.isEmpty {
                    // A spacer, so a quiet day is the same height as a busy one.
                    Color.clear.frame(height: 3)
                } else {
                    ForEach(Array(day.audiences.enumerated()), id: \.offset) { _, audience in
                        Capsule()
                            .fill(Palette.forAudience(audience))
                            .frame(height: 3)
                    }
                }
            }
            .frame(width: barWidth)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.minTarget)
        .padding(.top, isAtCap ? 7 : 8)
        .padding(.bottom, isAtCap ? 6 : 7)
        .container(
            surface: isToday ? Palette.paperLift : Palette.paper,
            radius: Metrics.rDayTile,
            elevation: isToday ? .hero : .sm,
            stroke: isAtCap ? Palette.amber : nil
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// The bars sit in the middle two-thirds of the tile so they read as a measure, not a fill.
    private var barWidth: CGFloat? {
        typeSize.isAccessibilitySize ? nil : 26
    }

    private var label: String {
        let date = day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if day.count == 0 { return "\(date), nothing scheduled" }
        let cap = isAtCap ? ", at the daily cap" : ""
        return "\(date), \(day.count) reminder\(day.count == 1 ? "" : "s")\(cap)"
    }
}

/// The day tile at accessibility sizes: the same information laid out along the row, where there
/// is room for it, instead of squeezed into a seventh of the width.
private struct DayRow: View {
    let day: DayLoad
    let isToday: Bool
    let isAtCap: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(day.day.formatted(.dateTime.weekday(.wide)))
                .font(.system(.body, weight: isToday ? .semibold : .regular))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(day.day.formatted(.dateTime.day().month(.abbreviated)))
                .font(.system(.body, design: .serif))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            HStack(spacing: 3) {
                ForEach(Array(day.audiences.enumerated()), id: \.offset) { _, audience in
                    Circle()
                        .fill(Palette.forAudience(audience))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(minHeight: Metrics.minTarget)
        .container(
            surface: isToday ? Palette.paperLift : Palette.paper,
            radius: Metrics.rDayTile,
            elevation: isToday ? .hero : .sm,
            stroke: isAtCap ? Palette.amber : nil
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let date = day.day.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if day.count == 0 { return "\(date), nothing scheduled" }
        let cap = isAtCap ? ", at the daily cap" : ""
        return "\(date), \(day.count) reminder\(day.count == 1 ? "" : "s")\(cap)"
    }
}

// MARK: - Event card

private struct UpcomingEventCard: View {
    let event: TrackedEvent
    let cap: Int

    private var nextStep: PrepStep? {
        (event.plan?.steps ?? [])
            .filter { $0.state.isSchedulable || $0.state == .fired }
            .min { ($0.snoozedUntil ?? $0.fireDate) < ($1.snoozedUntil ?? $1.fireDate) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .font(TypeRamp.eventTitleCompact())
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                DateChip(date: event.startDate, isCompressed: event.plan?.wasCompressed == true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 12)

            Rectangle().fill(Palette.hairlineSoft).frame(height: 1)

            if let nextStep {
                VStack(alignment: .leading, spacing: 0) {
                    Text("NEXT")
                        .font(.system(.caption2, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Palette.muted)

                    Text(nextStep.effectiveCopy)
                        .font(.system(.callout))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    HStack(spacing: 6) {
                        AudienceDot(audience: nextStep.audience)
                        Text(whenLine(nextStep).uppercased())
                            .font(.system(.caption2, weight: .medium))
                            .tracking(0.7)
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }

            RungFooter(plan: event.plan, cap: cap)
        }
        .container(radius: Metrics.rContainer, elevation: .lift)
        .clipShape(.rect(cornerRadius: Metrics.rContainer, style: .continuous))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func whenLine(_ step: PrepStep) -> String {
        let fire = step.snoozedUntil ?? step.fireDate
        let day = Calendar.current.isDateInToday(fire)
            ? "today"
            : fire.formatted(.dateTime.weekday(.wide))
        let who = step.audience == .me ? "to you" : "to your \(step.audience.displayName.lowercased())"
        return "\(day) · \(who)"
    }
}

/// `SUN 16`, or `TIGHT · MON 17` when the run-up had to be squeezed.
private struct DateChip: View {
    let date: Date
    let isCompressed: Bool

    var body: some View {
        Text(label)
            .font(.system(.caption2, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(isCompressed ? Palette.ink : Palette.graphite)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(
                Capsule().fill(isCompressed ? Palette.amber.opacity(0.14) : Palette.paperSunk)
            )
            .fixedSize()
    }

    private var label: String {
        let day = date.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
        return isCompressed ? "TIGHT · \(day)" : day
    }
}

// MARK: - Month grid

private struct MonthGrid: View {
    let asks: [ScheduledAsk]
    let total: Int
    let calendar: Calendar

    /// Every cell the grid draws, including the days either side that fill the first and last
    /// rows. Those are real dates rendered in `dateOutside` — a blank would break the reading of
    /// the month as a continuous run of weeks.
    private var cells: [(date: Date, isInMonth: Bool)] {
        guard let month = calendar.dateInterval(of: .month, for: .now) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: month.start)
        // Monday-first offset: Monday is weekday 2 in Gregorian.
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: month.start)?.count ?? 30

        var result: [(Date, Bool)] = []
        for offset in stride(from: leading, to: 0, by: -1) {
            if let date = calendar.date(byAdding: .day, value: -offset, to: month.start) {
                result.append((date, false))
            }
        }
        for offset in 0..<dayCount {
            if let date = calendar.date(byAdding: .day, value: offset, to: month.start) {
                result.append((date, true))
            }
        }
        var trailing = 0
        while result.count % 7 != 0 {
            trailing += 1
            if let date = calendar.date(byAdding: .day, value: dayCount + trailing - 1, to: month.start) {
                result.append((date, false))
            } else {
                break
            }
        }
        return result.map { (date: $0.0, isInMonth: $0.1) }
    }

    private var byDay: [Date: [Audience]] {
        Dictionary(grouping: asks) { calendar.startOfDay(for: $0.fireDate) }
            .mapValues { $0.sorted { $0.fireDate < $1.fireDate }.map(\.audience) }
    }

    private var weekdayInitials: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        // Rotate so the week starts on the calendar's own first weekday.
        let offset = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + offset) % 7] }
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7),
                      spacing: 1) {
                ForEach(Array(weekdayInitials.enumerated()), id: \.offset) { _, initial in
                    Text(initial)
                        .font(.system(.caption2))
                        .foregroundStyle(Palette.muted)
                        .padding(.bottom, 5)
                }

                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    MonthCell(
                        date: cell.date,
                        isInMonth: cell.isInMonth,
                        audiences: byDay[calendar.startOfDay(for: cell.date)] ?? [],
                        isToday: calendar.isDateInToday(cell.date)
                    )
                }
            }

            Rectangle()
                .fill(Palette.hairlineSoft)
                .frame(height: 1)
                .padding(.horizontal, -14)
                .padding(.top, 6)

            HStack(spacing: 12) {
                legendItem(.leaders, "leads")
                legendItem(.students, "students")
                legendItem(.me, "you")
                Spacer(minLength: 8)
                Text("\(total) in \(Date.now.formatted(.dateTime.month(.wide)))")
                    .font(.system(.caption2))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .container(radius: Metrics.rContainer, elevation: .tracked)
    }

    private func legendItem(_ audience: Audience, _ label: String) -> some View {
        HStack(spacing: 4) {
            AudienceDot(audience: audience)
            Text(label)
                .font(.system(.caption2))
                .foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MonthCell: View {
    let date: Date
    let isInMonth: Bool
    let audiences: [Audience]
    let isToday: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(date.formatted(.dateTime.day()))
                .font(.system(.caption))
                .fontWeight(isToday ? .semibold : .regular)
                .foregroundStyle(dateColor)
                // minWidth/minHeight, not frame(width:height:) — the circle is a graphic but the
                // date inside it is text, and text has to be free to grow at large type sizes.
                .padding(3)
                .frame(minWidth: 23, minHeight: 23)
                .background {
                    if isToday { Circle().fill(Palette.ink) }
                }

            HStack(spacing: 3) {
                if audiences.isEmpty {
                    // A spacer, so rows stay aligned whether or not a day carries anything.
                    Color.clear.frame(height: 4)
                } else {
                    ForEach(Array(audiences.prefix(3).enumerated()), id: \.offset) { _, audience in
                        Circle()
                            .fill(Palette.forAudience(audience))
                            .frame(width: 4, height: 4)
                    }
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHidden(!isInMonth && audiences.isEmpty)
    }

    private var dateColor: Color {
        if isToday { return Palette.paper }
        return isInMonth ? Palette.ink : Palette.dateOutside
    }

    private var label: String {
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        if audiences.isEmpty { return day }
        return "\(day), \(audiences.count) reminder\(audiences.count == 1 ? "" : "s")"
    }
}

// MARK: - Week container

private struct WeekContainer: View {
    let start: Date
    let rows: [(event: TrackedEvent, date: Date, audience: Audience)]
    let onOpen: (TrackedEvent) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("WEEK OF \(start.formatted(.dateTime.day().month(.abbreviated)).uppercased())")
                    .font(.system(.caption2, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                Text("\(rows.count) ask\(rows.count == 1 ? "" : "s")")
                    .font(.system(.caption2))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Rectangle().fill(Palette.hairlineSoft).frame(height: 1)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle().fill(Palette.hairlineSoft).frame(height: 1)
                        .padding(.leading, 16)
                }
                Button { onOpen(row.event) } label: {
                    HStack(spacing: 10) {
                        AudienceDot(audience: row.audience)
                        Text(row.event.title)
                            .font(TypeRamp.eventTitleCompact())
                            .foregroundStyle(Palette.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Text(row.date.formatted(.dateTime.weekday(.abbreviated).day()).uppercased())
                            .font(.system(.caption2))
                            .tracking(0.5)
                            .foregroundStyle(Palette.muted)
                            .fixedSize()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .container(radius: Metrics.rCard, elevation: .md)
        .clipShape(.rect(cornerRadius: Metrics.rCard, style: .continuous))
    }
}
